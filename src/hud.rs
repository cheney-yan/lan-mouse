//! Local, fire-and-forget notifications for an optional on-screen HUD.
//!
//! One JSON object per UDP datagram to `LAN_MOUSE_HUD_ADDR` (default
//! `127.0.0.1:4243`). Platform independent; the HUD programs live in
//! `tools/hud` (macOS) and `tools/hud-wayland` (Linux).
//!
//! Events (`position` is an edge of *this* device, `fraction` 0..1 along it,
//! 0 = top/left end):
//! - `enter_remote`: a remote cursor entered this device
//! - `leave_local`: our cursor left through that edge to a remote
//! - `return_local`: our cursor came back through that edge
//! - `locate`: the user asked where the mouse is
use lan_mouse_ipc::Position;
use std::net::UdpSocket;

fn pos_name(pos: Position) -> &'static str {
    match pos {
        Position::Left => "left",
        Position::Right => "right",
        Position::Top => "top",
        Position::Bottom => "bottom",
    }
}

fn send(json: String) {
    let addr = std::env::var("LAN_MOUSE_HUD_ADDR").unwrap_or_else(|_| "127.0.0.1:4243".to_string());
    if let Ok(sock) = UdpSocket::bind("127.0.0.1:0") {
        let _ = sock.send_to(json.as_bytes(), addr);
    }
}

pub(crate) fn edge_event(event: &str, pos: Position, fraction: Option<f64>) {
    let frac = fraction.map(|f| format!("{f:.4}")).unwrap_or_else(|| "null".into());
    send(format!(
        "{{\"event\":\"{event}\",\"position\":\"{}\",\"fraction\":{frac}}}",
        pos_name(pos)
    ));
}

pub(crate) fn simple_event(event: &str) {
    send(format!("{{\"event\":\"{event}\"}}"));
}
