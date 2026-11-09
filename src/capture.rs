use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    time::{Duration, Instant},
};

use futures::StreamExt;
use input_capture::{
    CaptureError, CaptureEvent, CaptureHandle, InputCapture, InputCaptureError, Position,
};
use input_event::{Event, KeyboardEvent, scancode};
use lan_mouse_proto::ProtoEvent;
use local_channel::mpsc::{Receiver, Sender, channel};
use tokio::task::{JoinHandle, spawn_local};
use tokio_util::sync::CancellationToken;

use crate::connect::LanMouseConnection;

pub(crate) struct Capture {
    cancellation_token: CancellationToken,
    request_tx: Sender<CaptureRequest>,
    task: JoinHandle<()>,
    event_rx: Receiver<ICaptureEvent>,
}

pub(crate) enum ICaptureEvent {
    /// a client was entered
    CaptureBegin(CaptureHandle),
    /// the capture of this client ended (Leave sent, or no client was active)
    CaptureReleased(Option<CaptureHandle>),
    /// capture disabled
    CaptureDisabled,
    /// capture disabled
    CaptureEnabled,
    /// A (new) client was entered.
    /// In contrast to [`ICaptureEvent::CaptureBegin`] this
    /// event is only triggered when the capture was
    /// explicitly released in the meantime by
    /// either the remote client leaving its device region,
    /// a new device entering the screen or the release bind.
    ClientEntered(u64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CaptureType {
    /// a normal input capture
    Default,
    /// A capture only interested in [`CaptureEvent::Begin`] events.
    /// The capture is released immediately, if there is no
    /// Default capture at the same position.
    EnterOnly,
}

#[derive(Clone, Debug)]
enum CaptureRequest {
    /// capture must release the mouse
    Release,
    /// enter a client programmatically
    Enter(CaptureHandle),
    /// the cursor returns from this client through `fraction` of its edge
    SetReturnPoint(CaptureHandle, f64),
    /// add a capture client
    Create(CaptureHandle, Position, CaptureType),
    /// destory a capture client
    Destroy(CaptureHandle),
    /// reenable input capture
    Reenable,
    /// set release bind
    SetReleaseBind(Vec<scancode::Linux>),
}

impl Capture {
    pub(crate) fn new(
        backend: Option<input_capture::Backend>,
        conn: LanMouseConnection,
        release_bind: Vec<scancode::Linux>,
    ) -> Self {
        let (request_tx, request_rx) = channel();
        let (event_tx, event_rx) = channel();
        let cancellation_token = CancellationToken::new();
        let capture_task = CaptureTask {
            ack_deadline: None,
            entered_at: None,
            locate_sent: false,
            pending_fraction: None,
            enter_fraction: None,
            enter_resends: 0,
            active_client: None,
            backend,
            cancellation_token: cancellation_token.clone(),
            captures: Default::default(),
            conn,
            event_tx,
            request_rx,
            release_bind: Rc::new(RefCell::new(release_bind)),
            state: Default::default(),
        };
        let task = spawn_local(capture_task.run());
        Self {
            cancellation_token,
            request_tx,
            task,
            event_rx,
        }
    }

    pub(crate) fn reenable(&self) {
        self.request_tx
            .send(CaptureRequest::Reenable)
            .expect("channel closed");
    }

    pub(crate) async fn terminate(&mut self) {
        self.cancellation_token.cancel();
        log::debug!("terminating capture");
        if let Err(e) = (&mut self.task).await {
            log::warn!("{e}");
        }
    }

    pub(crate) fn create(
        &self,
        handle: CaptureHandle,
        pos: lan_mouse_ipc::Position,
        capture_type: CaptureType,
    ) {
        let pos = to_capture_pos(pos);
        self.request_tx
            .send(CaptureRequest::Create(handle, pos, capture_type))
            .expect("channel closed");
    }

    pub(crate) fn destroy(&self, handle: CaptureHandle) {
        self.request_tx
            .send(CaptureRequest::Destroy(handle))
            .expect("channel closed");
    }

    pub(crate) fn release(&self) {
        self.request_tx
            .send(CaptureRequest::Release)
            .expect("channel closed");
    }

    pub(crate) fn enter(&self, handle: CaptureHandle) {
        self.request_tx
            .send(CaptureRequest::Enter(handle))
            .expect("channel closed");
    }

    pub(crate) fn set_return_point(&self, handle: CaptureHandle, fraction: f64) {
        self.request_tx
            .send(CaptureRequest::SetReturnPoint(handle, fraction))
            .expect("channel closed");
    }

    pub(crate) async fn event(&mut self) -> ICaptureEvent {
        self.event_rx.recv().await.expect("channel closed")
    }

    pub(crate) fn set_release_bind(&mut self, bind: Vec<scancode::Linux>) {
        let _ = self.request_tx.send(CaptureRequest::SetReleaseBind(bind));
    }
}

/// debounce a statement `$st`, i.e. the statement is executed only if the
/// time since the previous execution is at least `$dur`.
/// `$prev` is used to keep track of this timestamp
macro_rules! debounce {
    ($prev:ident, $dur:expr, $st:stmt) => {
        let exec = match $prev.get() {
            None => true,
            Some(instant) if instant.elapsed() > $dur => true,
            _ => false,
        };
        if exec {
            $prev.replace(Some(Instant::now()));
            $st
        }
    };
}

/// how long we wait for the remote to acknowledge an `Enter` before giving
/// the input back to the local machine (stale connection, remote hung, ...)
const ACK_TIMEOUT: Duration = Duration::from_millis(1500);

/// how often we make sure every active client has a live connection, so
/// the first crossing after start-up (or after a drop) does not have to
/// wait for a DTLS handshake
const WARM_INTERVAL: Duration = Duration::from_secs(10);

/// Where along the shared edge the cursor appears on the other device.
/// LAN_MOUSE_ENTRY=center: always the middle of the edge. Otherwise
/// (default) the same *proportion* of the edge the cursor crossed at: the
/// fraction 0..1 travels in the protocol and each side maps it onto its own
/// edge length, so differing resolutions cannot misplace it.
fn entry_fraction() -> Option<f64> {
    match std::env::var("LAN_MOUSE_ENTRY").as_deref() {
        Ok("center") => Some(0.5),
        _ => None,
    }
}

/// LAN_MOUSE_NO_PLACEMENT=1 switches every automatic cursor placement off:
/// we send the legacy Enter (no position) and ignore positions we receive.
/// The cursor then only ever moves with the user's hand.
pub(crate) fn placement_disabled() -> bool {
    std::env::var_os("LAN_MOUSE_NO_PLACEMENT").is_some()
}

/// Ctrl+Alt+Meta+K while a client is captured: give the mouse back
/// (the same chord is used by the HUD to *enter* a client when local)
const TOGGLE_BIND: [scancode::Linux; 4] = [
    scancode::Linux::KeyLeftCtrl,
    scancode::Linux::KeyLeftAlt,
    scancode::Linux::KeyLeftMeta,
    scancode::Linux::KeyK,
];
/// Ctrl+Alt+Meta+L while a client is captured: ask the HUD to show
/// where the mouse went (the HUD cannot see keys while we capture them)
const LOCATE_BIND: [scancode::Linux; 4] = [
    scancode::Linux::KeyLeftCtrl,
    scancode::Linux::KeyLeftAlt,
    scancode::Linux::KeyLeftMeta,
    scancode::Linux::KeyL,
];

fn notify_hud(event: &str) {
    let addr = std::env::var("LAN_MOUSE_HUD_ADDR").unwrap_or_else(|_| "127.0.0.1:4243".to_string());
    if let Ok(sock) = std::net::UdpSocket::bind("127.0.0.1:0") {
        let _ = sock.send_to(format!("{{\"event\":\"{event}\"}}").as_bytes(), addr);
    }
}

async fn wait_until(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(d) => tokio::time::sleep_until(d).await,
        None => std::future::pending().await,
    }
}

struct CaptureTask {
    /// deadline for the remote to acknowledge an `Enter`
    ack_deadline: Option<tokio::time::Instant>,
    /// when the current client was entered
    entered_at: Option<Instant>,
    /// locate chord already reported for the current key-down
    locate_sent: bool,
    /// edge fraction announced by the backend for the next `Begin`
    pending_fraction: Option<f64>,
    /// edge fraction of the active client's entry (None = backend did not say)
    enter_fraction: Option<f64>,
    /// how many `Enter`s were (re)sent while waiting for the Ack
    enter_resends: u32,
    active_client: Option<CaptureHandle>,
    backend: Option<input_capture::Backend>,
    cancellation_token: CancellationToken,
    captures: Vec<(CaptureHandle, Position, CaptureType)>,
    conn: LanMouseConnection,
    event_tx: Sender<ICaptureEvent>,
    release_bind: Rc<RefCell<Vec<scancode::Linux>>>,
    request_rx: Receiver<CaptureRequest>,
    state: State,
}

impl CaptureTask {
    fn add_capture(&mut self, handle: CaptureHandle, pos: Position, capture_type: CaptureType) {
        self.captures.push((handle, pos, capture_type));
    }

    fn remove_capture(&mut self, handle: CaptureHandle) {
        self.captures.retain(|&(h, ..)| handle != h);
    }

    fn is_default_capture_at(&self, pos: Position) -> bool {
        self.captures
            .iter()
            .any(|&(_, p, t)| p == pos && t == CaptureType::Default)
    }

    fn get_pos(&self, handle: CaptureHandle) -> Position {
        self.captures
            .iter()
            .find(|(h, ..)| *h == handle)
            .expect("no such capture")
            .1
    }

    fn get_type(&self, handle: CaptureHandle) -> CaptureType {
        self.captures
            .iter()
            .find(|(h, ..)| *h == handle)
            .expect("no such capture")
            .2
    }

    async fn run(mut self) {
        loop {
            if let Err(e) = self.do_capture().await {
                log::warn!("input capture exited: {e}");
            }
            loop {
                tokio::select! {
                    r = self.request_rx.recv() => match r.expect("channel closed") {
                        CaptureRequest::Reenable => break,
                        CaptureRequest::Create(h, p, t) => self.add_capture(h, p, t),
                        CaptureRequest::Destroy(h) => self.remove_capture(h),
                        CaptureRequest::Release | CaptureRequest::Enter(_) | CaptureRequest::SetReturnPoint(..) => { /* nothing to do */ }
                        CaptureRequest::SetReleaseBind(bind) => {
                            self.release_bind.borrow_mut().clone_from(&bind);
                        }
                    },
                    _ = self.cancellation_token.cancelled() => return,
                }
            }
        }
    }

    async fn do_capture(&mut self) -> Result<(), InputCaptureError> {
        /* allow cancelling capture request */
        let mut capture = tokio::select! {
            r = InputCapture::new(self.backend) => r?,
            _ = self.cancellation_token.cancelled() => return Ok(()),
        };

        let _capture_guard = DropGuard::new(
            self.event_tx.clone(),
            ICaptureEvent::CaptureEnabled,
            ICaptureEvent::CaptureDisabled,
        );

        /* create barriers for active clients */
        let r = self.create_captures(&mut capture).await;
        if let Err(e) = r {
            capture.terminate().await?;
            return Err(e.into());
        }

        let r = self.do_capture_session(&mut capture).await;

        // FIXME replace with async drop when stabilized
        capture.terminate().await?;

        r
    }

    async fn create_captures(&mut self, capture: &mut InputCapture) -> Result<(), CaptureError> {
        let captures = self.captures.clone();
        for (handle, pos, _type) in captures {
            tokio::select! {
                r = capture.create(handle, pos) => r?,
                _ = self.cancellation_token.cancelled() => return Ok(()),
            }
        }
        Ok(())
    }

    async fn do_capture_session(
        &mut self,
        capture: &mut InputCapture,
    ) -> Result<(), InputCaptureError> {
        let mut warm = tokio::time::interval(WARM_INTERVAL);
        warm.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let ack_deadline = self.ack_deadline;
            tokio::select! {
                _ = warm.tick() => {
                    // a Ping to a not-yet-connected client triggers the
                    // connection attempt; to a connected one it is harmless
                    let handles: Vec<CaptureHandle> = self.captures.iter()
                        .filter(|(_, _, t)| *t == CaptureType::Default)
                        .map(|(h, _, _)| *h)
                        .collect();
                    for h in handles {
                        let _ = self.conn.send(ProtoEvent::Ping, h).await;
                    }
                },
                event = capture.next() => match event {
                    Some(event) => self.handle_capture_event(capture, event?).await?,
                    None => return Ok(()),
                },
                _ = wait_until(ack_deadline), if ack_deadline.is_some() => {
                    log::warn!(
                        "releasing capture: client {:?} did not acknowledge within {:?}",
                        self.active_client, ACK_TIMEOUT
                    );
                    self.ack_deadline = None;
                    self.release_capture(capture).await?;
                },
                (handle, event) = self.conn.recv() => {
                    if let Some(active) = self.active_client {
                        if handle != active {
                            // we only care about events coming from the client we are currently connected to
                            // only `Ack` and `Leave` are relevant
                            continue
                        }
                    }

                    match event {
                        // connection acknowlegded => set state to Sending
                        ProtoEvent::Ack(_) => {
                            log::info!("client {handle} acknowledged the connection!");
                            self.state = State::Sending;
                            self.ack_deadline = None;
                        }
                        // client disconnected
                        ProtoEvent::Leave(_) => {
                            // a Leave from the client we are sending to always
                            // gives the input back: the user must never be stuck
                            log::info!("releasing capture: left remote client device region");
                            self.release_capture(capture).await?;
                        },
                        _ => {}
                    }
                },
                e = self.request_rx.recv() => match e.expect("channel closed") {
                    CaptureRequest::Reenable => { /* already active */ },
                    CaptureRequest::Release => self.release_capture(capture).await?,
                    CaptureRequest::Enter(h) => {
                        if let Err(e) = capture.enter(h).await {
                            log::warn!("could not enter client {h}: {e}");
                        }
                    }
                    CaptureRequest::SetReturnPoint(h, f) => {
                        if let Err(e) = capture.set_return_point(h, f).await {
                            log::warn!("could not set return point for client {h}: {e}");
                        }
                    }
                    CaptureRequest::Create(h, p, t) => {
                        self.add_capture(h, p, t);
                        capture.create(h, p).await?;
                    }
                    CaptureRequest::Destroy(h) => {
                        self.remove_capture(h);
                        capture.destroy(h).await?;
                    }
                    CaptureRequest::SetReleaseBind(bind) => {
                        self.release_bind.borrow_mut().clone_from(&bind);
                    }
                },
                _ = self.cancellation_token.cancelled() => break,
            }
        }
        Ok(())
    }

    async fn handle_capture_event(
        &mut self,
        capture: &mut InputCapture,
        event: (CaptureHandle, CaptureEvent),
    ) -> Result<(), CaptureError> {
        let (handle, event) = event;
        log::trace!("({handle}): {event:?}");

        if let CaptureEvent::EdgeFraction(f) = event {
            self.pending_fraction = Some(f);
            return Ok(());
        }

        if capture.keys_pressed(&self.release_bind.borrow()) {
            log::info!("releasing capture: release-bind pressed");
            return self.release_capture(capture).await;
        }
        if capture.keys_pressed(&TOGGLE_BIND) {
            log::info!("releasing capture: toggle chord pressed");
            return self.release_capture(capture).await;
        }
        if capture.keys_pressed(&LOCATE_BIND) {
            if !self.locate_sent {
                self.locate_sent = true;
                notify_hud("locate");
            }
        } else {
            self.locate_sent = false;
        }

        if event == CaptureEvent::Begin {
            self.event_tx
                .send(ICaptureEvent::CaptureBegin(handle))
                .expect("channel closed");
        }

        // enter only capture (for incoming connections)
        if self.get_type(handle) == CaptureType::EnterOnly {
            // if there is no active outgoing connection at the current capture,
            // we release the capture
            if !self.is_default_capture_at(self.get_pos(handle)) {
                log::info!("releasing capture: no active client at this position");
                capture.release().await?;
            }
            // we dont care about events from incoming handles except for releasing the capture
            return Ok(());
        }

        // activated a new client
        if event == CaptureEvent::Begin && Some(handle) != self.active_client {
            self.state = State::WaitingForAck;
            self.ack_deadline = Some(tokio::time::Instant::now() + ACK_TIMEOUT);
            self.entered_at = Some(Instant::now());
            self.enter_fraction = self.pending_fraction.take();
            self.enter_resends = 0;
            self.active_client.replace(handle);
            self.event_tx
                .send(ICaptureEvent::ClientEntered(handle))
                .expect("channel closed");
        }

        let opposite_pos = to_proto_pos(self.get_pos(handle).opposite());

        // EnterAt carries the crossing point. Upstream peers drop the
        // connection on an unknown event, so it is only sent to peers that
        // announced support in their Pong; everyone else gets the legacy Enter.
        let capable = self.conn.supports_enter_at(handle) && !placement_disabled();
        let enter_event = |frac: Option<f64>| match entry_fraction().or(frac) {
            Some(f) if capable => ProtoEvent::EnterAt(opposite_pos, f),
            _ => ProtoEvent::Enter(opposite_pos),
        };
        let event = match event {
            CaptureEvent::EdgeFraction(_) => unreachable!("handled above"),
            CaptureEvent::Begin => enter_event(self.enter_fraction),
            CaptureEvent::Input(e) => match self.state {
                // connection not acknowledged, repeat `Enter` event
                State::WaitingForAck => {
                    self.enter_resends = self.enter_resends.wrapping_add(1);
                    enter_event(self.enter_fraction)
                }
                State::Sending => ProtoEvent::Input(e),
            },
        };

        if let Err(e) = self.conn.send(event, handle).await {
            const DUR: Duration = Duration::from_millis(500);
            debounce!(PREV_LOG, DUR, log::warn!("releasing capture: {e}"));
            capture.release().await?;
        }
        Ok(())
    }

    async fn release_capture(&mut self, capture: &mut InputCapture) -> Result<(), CaptureError> {
        self.ack_deadline = None;
        self.entered_at = None;
        let released = self.active_client;
        let _ = self.event_tx.send(ICaptureEvent::CaptureReleased(released));
        // If we have an active client, notify them we're leaving
        if let Some(handle) = self.active_client.take() {
            // Synthesize key-up events for every key still held in the
            // capture's pressed_keys set BEFORE sending Leave. Without
            // this, pressing the release-bind chord (typically all four
            // modifiers) leaves the peer with phantom held modifiers:
            // the down events were forwarded while capture was active,
            // but the matching up events arrive after the local tap
            // flips to passthrough and never reach the peer. The peer
            // then runs every subsequent keystroke through those held
            // mods until its watchdog times out (1+ s) or our Leave
            // arrives — and Leave can be lost over UDP/DTLS.
            for key in capture.take_pressed_keys() {
                let key_up = ProtoEvent::Input(Event::Keyboard(KeyboardEvent::Key {
                    time: 0,
                    key: key as u32,
                    state: 0,
                }));
                if let Err(e) = self.conn.send(key_up, handle).await {
                    log::warn!("failed to send key-up to client {handle}: {e}");
                }
            }
            // Reset the modifier mask too. The peer's input-emulation
            // layer keeps a separate XKB-style modifier state that's
            // updated by KeyboardEvent::Modifiers, distinct from the
            // pressed_keys set drained above. Without this, an
            // already-locked CapsLock would survive the release.
            let mods_zero = ProtoEvent::Input(Event::Keyboard(KeyboardEvent::Modifiers {
                depressed: 0,
                latched: 0,
                locked: 0,
                group: 0,
            }));
            if let Err(e) = self.conn.send(mods_zero, handle).await {
                log::warn!("failed to reset modifiers on client {handle}: {e}");
            }

            log::info!("sending Leave event to client {handle}");
            if let Err(e) = self.conn.send(ProtoEvent::Leave(0), handle).await {
                log::warn!("failed to send Leave to client {handle}: {e}");
            }
        }
        capture.release().await
    }
}

thread_local! {
    static PREV_LOG: Cell<Option<Instant>> = const { Cell::new(None) };
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum State {
    #[default]
    WaitingForAck,
    Sending,
}

fn to_capture_pos(pos: lan_mouse_ipc::Position) -> input_capture::Position {
    match pos {
        lan_mouse_ipc::Position::Left => input_capture::Position::Left,
        lan_mouse_ipc::Position::Right => input_capture::Position::Right,
        lan_mouse_ipc::Position::Top => input_capture::Position::Top,
        lan_mouse_ipc::Position::Bottom => input_capture::Position::Bottom,
    }
}

fn to_proto_pos(pos: input_capture::Position) -> lan_mouse_proto::Position {
    match pos {
        input_capture::Position::Left => lan_mouse_proto::Position::Left,
        input_capture::Position::Right => lan_mouse_proto::Position::Right,
        input_capture::Position::Top => lan_mouse_proto::Position::Top,
        input_capture::Position::Bottom => lan_mouse_proto::Position::Bottom,
    }
}

struct DropGuard<T> {
    tx: Sender<T>,
    on_drop: Option<T>,
}

impl<T> DropGuard<T> {
    fn new(tx: Sender<T>, on_new: T, on_drop: T) -> Self {
        tx.send(on_new).expect("channel closed");
        let on_drop = Some(on_drop);
        Self { tx, on_drop }
    }
}

impl<T> Drop for DropGuard<T> {
    fn drop(&mut self) {
        self.tx
            .send(self.on_drop.take().expect("item"))
            .expect("channel closed");
    }
}
