//! Windows system-tray battery indicator for the Dygma Defy wireless.
//!
//! A hidden window owns a Shell_NotifyIcon tray icon; a background thread
//! owns the Focus serial connection and runs the same discover -> connect ->
//! poll loop as the CLI, waking the UI thread with PostMessageW on every new
//! reading. The icon shows the *lower* of the two sides' battery percentage;
//! the tooltip carries the full both-sides detail. Windows only.

const std = @import("std");
const builtin = @import("builtin");
const focus = @import("focus.zig");
const battery = @import("battery.zig");
const device = @import("device.zig");
const windows = std.os.windows;

// ---------------------------------------------------------------------------
// Win32 type aliases and structs (std.os.windows lacks the GUI surface).
// ---------------------------------------------------------------------------
const UINT = u32;
const DWORD = windows.DWORD;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const COLORREF = u32;
const BOOL = windows.BOOL;
const HWND = windows.HWND;
const HICON = windows.HICON;
const HMENU = windows.HMENU;
const HINSTANCE = windows.HINSTANCE;
const ATOM = windows.ATOM;
const HDC = *opaque {};
const HBITMAP = *opaque {};
const HFONT = *opaque {};
const HBRUSH = *opaque {};
const HCURSOR = HICON;
const HGDIOBJ = *anyopaque;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: ?HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uVersion: UINT, // union with uTimeout
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: windows.GUID,
    hBalloonIcon: ?HICON,
};

const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: ?HBITMAP,
    hbmColor: ?HBITMAP,
};

// ---------------------------------------------------------------------------
// Win32 externs.
// ---------------------------------------------------------------------------
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn CreateMutexW(lpMutexAttributes: ?*anyopaque, bInitialOwner: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) i32;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn SetMenuDefaultItem(hMenu: HMENU, uItem: UINT, fByPos: UINT) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: ?*const anyopaque) callconv(.winapi) ?HCURSOR;
extern "user32" fn DrawTextW(hdc: HDC, lpchText: [*]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;
extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) i32;

extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: i32, cy: i32) callconv(.winapi) ?HBITMAP;
extern "gdi32" fn CreateBitmap(nWidth: i32, nHeight: i32, nPlanes: UINT, nBitCount: UINT, lpBits: ?*const anyopaque) callconv(.winapi) ?HBITMAP;
extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: ?[*:0]const u16,
) callconv(.winapi) ?HFONT;
extern "gdi32" fn CreateIconIndirect(piconinfo: *ICONINFO) callconv(.winapi) ?HICON;

extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Win32 constants.
// ---------------------------------------------------------------------------
const WM_APP = 0x8000;
const WM_TRAYICON: UINT = WM_APP + 1;
const WM_BATTERY_UPDATE: UINT = WM_APP + 2;
const WM_NULL: UINT = 0x0000;
const WM_DESTROY: UINT = 0x0002;
const WM_CONTEXTMENU: u16 = 0x007B;
const WM_RBUTTONUP: u16 = 0x0205;
const WM_LBUTTONDBLCLK: u16 = 0x0203;

const NIM_ADD: DWORD = 0;
const NIM_MODIFY: DWORD = 1;
const NIM_DELETE: DWORD = 2;
const NIM_SETVERSION: DWORD = 4;

const NIF_MESSAGE: UINT = 0x01;
const NIF_ICON: UINT = 0x02;
const NIF_TIP: UINT = 0x04;
const NIF_INFO: UINT = 0x10;
// Required with NOTIFYICON_VERSION_4 to keep the standard Shell tooltip.
const NIF_SHOWTIP: UINT = 0x80;
const NOTIFYICON_VERSION_4: UINT = 4;
const NIIF_INFO_ICON: DWORD = 0x01;
const NIIF_WARNING: DWORD = 0x02;

const MF_STRING: UINT = 0x0000;
const MF_GRAYED: UINT = 0x0001; // disabled + dimmed (non-selectable label)
const MF_SEPARATOR: UINT = 0x0800;
const MF_BYCOMMAND: UINT = 0x0000;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_RETURNCMD: UINT = 0x0100;

const DT_CENTER: UINT = 0x01;
const DT_VCENTER: UINT = 0x04;
const DT_SINGLELINE: UINT = 0x20;
const DT_NOCLIP: UINT = 0x100;
const TRANSPARENT: i32 = 1;
const WS_OVERLAPPED: DWORD = 0x00000000;
const IDC_ARROW: usize = 32512;
const DEFAULT_CHARSET: DWORD = 1;
const FW_BOLD: i32 = 700;

const ID_REFRESH: i32 = 1;
const ID_QUIT: i32 = 2;
const ID_TOGGLE: i32 = 3;

const icon_size: i32 = 16;
const low_threshold: u8 = 20;
// Poll cadence. The wireless halves sleep and the neuron only serves a cached
// value once a side has reported, so a plain read right after connect is often
// empty. Polling frequently (like the Go tray's default 5s) catches a real
// reading within a few seconds; last-known-good then keeps it across the empty
// reads that follow. Plain reads hit the USB-powered neuron only — they never
// wake the sides or wear flash, so a tight interval is cheap.
const poll_interval_ms: u64 = 5 * 1000;

// Status colors, COLORREF (0x00BBGGRR).
fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}
const col_green = rgb(46, 160, 67);
const col_amber = rgb(200, 140, 0);
const col_red = rgb(220, 50, 47);
const col_blue = rgb(41, 128, 185);
const col_gray = rgb(110, 110, 110);
const col_text = rgb(255, 255, 255);

const ERROR_ALREADY_EXISTS: DWORD = 183;
const singleton_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\DygmaBatteryTraySingleton");

const notification_title_battery = "Dygma Defy battery level";
const notification_title_low = "Dygma Defy battery low";

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("DygmaBatteryTrayWnd");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("dygma-battery");
const menu_refresh = std.unicode.utf8ToUtf16LeStringLiteral("Refresh battery now");
const menu_disconnect = std.unicode.utf8ToUtf16LeStringLiteral("Disconnect (release port for Bazecor)");
const menu_reconnect = std.unicode.utf8ToUtf16LeStringLiteral("Reconnect");
const menu_quit = std.unicode.utf8ToUtf16LeStringLiteral("Quit");

// ---------------------------------------------------------------------------
// Shared state between the UI thread and the polling thread.
// ---------------------------------------------------------------------------
const State = struct {
    mutex: std.Io.Mutex = .init,
    reading: ?battery.Reading = null,
    connected: bool = false,
    announce_connection: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    refresh: std.atomic.Value(bool) = .init(false),
    /// User asked us to release the port (so Bazecor can use it). The poll
    /// thread closes the connection and idles until this clears.
    paused: std.atomic.Value(bool) = .init(false),
    /// UI-thread-only: latched per side (0=left, 1=right) so a low-battery
    /// balloon fires once per crossing, not every poll.
    notified_low: [2]bool = .{ false, false },
};

const PollCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    hwnd: HWND,
    state: *State,
};

var g_state: State = .{};
var g_nid: NOTIFYICONDATAW = undefined;
/// The process Io, shared by the UI and polling threads (Threaded io is
/// thread-safe). Stashed globally so the UI thread can lock the state mutex.
var g_io: std.Io = undefined;

// Last-known-good reading, per side (UI thread only). The wireless halves
// sleep and report a null level and/or empty status between the (now 15-60 min)
// polls; rather than show "?%" or "(?)", we keep the last real value for each
// field independently (see updateTray). Persists across sleep and disconnect —
// the battery hasn't changed — so hovering always reveals a real number.
// `level == null` / `status == .unknown` means that field has never reported yet.
var g_last_left: battery.SideReading = .{ .level = null, .status = .unknown };
var g_last_right: battery.SideReading = .{ .level = null, .status = .unknown };

pub fn main(init: std.process.Init) void {
    g_io = init.io;

    // Single instance only: a second copy could never open the exclusive COM
    // port anyway, and would just show a confusing duplicate "--" icon. The
    // mutex handle is intentionally leaked — the OS frees it when we exit.
    _ = CreateMutexW(null, .FALSE, singleton_name);
    if (GetLastError() == ERROR_ALREADY_EXISTS) return;

    const hinst = GetModuleHandleW(null).?;

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW));
    wc.lpszClassName = class_name;
    _ = RegisterClassExW(&wc);

    // A normal (never-shown) window rather than message-only, so
    // SetForegroundWindow works and the context menu dismisses on click-away.
    const hwnd = CreateWindowExW(0, class_name, window_title, WS_OVERLAPPED, 0, 0, 0, 0, null, null, hinst, null) orelse return;

    g_nid = std.mem.zeroes(NOTIFYICONDATAW);
    g_nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    g_nid.hWnd = hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = makeTextIcon("--", col_gray);
    setUtf16(g_nid.szTip[0..], "dygma-battery: starting\u{2026}");
    _ = Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_nid.uVersion = NOTIFYICON_VERSION_4;
    _ = Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
    g_nid.uFlags = NIF_TIP | NIF_SHOWTIP;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    var ctx = PollCtx{ .io = init.io, .gpa = init.gpa, .hwnd = hwnd, .state = &g_state };
    const thread = std.Thread.spawn(.{}, pollLoop, .{&ctx}) catch {
        _ = Shell_NotifyIconW(NIM_DELETE, &g_nid);
        return;
    };

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    g_state.stop.store(true, .release);
    thread.join();
    if (g_nid.hIcon) |icon| _ = DestroyIcon(icon);
    _ = Shell_NotifyIconW(NIM_DELETE, &g_nid);
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_TRAYICON => {
            // With NOTIFYICON_VERSION_4 the event id is LOWORD(lParam).
            const event: u16 = @truncate(@as(usize, @bitCast(lparam)));
            if (event == WM_CONTEXTMENU or event == WM_RBUTTONUP) {
                showMenu(hwnd);
            } else if (event == WM_LBUTTONDBLCLK) {
                g_state.refresh.store(true, .release);
            }
            return 0;
        },
        WM_BATTERY_UPDATE => {
            updateTray();
            return 0;
        },
        WM_DESTROY => {
            g_state.stop.store(true, .release);
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn showMenu(hwnd: HWND) void {
    const paused = g_state.paused.load(.acquire);
    const menu = CreatePopupMenu() orelse return;
    defer _ = DestroyMenu(menu);

    // Informational (grayed, non-clickable) status header, mirroring the
    // tooltip: connection state + last-known level per side. g_last_* are
    // UI-thread-only, so no lock is needed for them; connected needs the mutex.
    g_state.mutex.lockUncancelable(g_io);
    const connected = g_state.connected;
    g_state.mutex.unlock(g_io);

    const conn_text: []const u8 = if (paused)
        "Paused (port free for Bazecor)"
    else if (connected)
        "Connected"
    else
        "Not connected";

    var lb: [48]u8 = undefined;
    var rb: [48]u8 = undefined;
    var sb: [24]u8 = undefined;
    appendMenuText(menu, MF_GRAYED, 0, conn_text);
    appendMenuText(menu, MF_GRAYED, 0, std.fmt.bufPrint(&lb, "Left: {s}", .{fmtMenuSide(&sb, g_last_left)}) catch "Left: ?");
    appendMenuText(menu, MF_GRAYED, 0, std.fmt.bufPrint(&rb, "Right: {s}", .{fmtMenuSide(&sb, g_last_right)}) catch "Right: ?");
    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);

    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_REFRESH), menu_refresh);
    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_TOGGLE), if (paused) menu_reconnect else menu_disconnect);
    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_QUIT), menu_quit);
    // Bold "Refresh battery now" as the default (also the double-click action).
    _ = SetMenuDefaultItem(menu, @intCast(ID_REFRESH), MF_BYCOMMAND);

    var pt: POINT = undefined;
    _ = GetCursorPos(&pt);
    // Required so the menu receives focus and dismisses when clicked away.
    _ = SetForegroundWindow(hwnd);
    const cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, pt.x, pt.y, 0, hwnd, null);
    _ = PostMessageW(hwnd, WM_NULL, 0, 0);

    switch (cmd) {
        ID_REFRESH => g_state.refresh.store(true, .release),
        ID_TOGGLE => {
            const now_paused = !paused;
            g_state.paused.store(now_paused, .release);
            // On reconnect, nudge the poll loop to re-scan immediately.
            if (!now_paused) g_state.refresh.store(true, .release);
            // Reflect the new state in the icon/tooltip right away.
            _ = PostMessageW(hwnd, WM_BATTERY_UPDATE, 0, 0);
        },
        ID_QUIT => {
            g_state.stop.store(true, .release);
            _ = Shell_NotifyIconW(NIM_DELETE, &g_nid);
            PostQuitMessage(0);
        },
        else => {},
    }
}

/// Rebuild the tray icon + tooltip from the latest reading. UI thread only.
fn updateTray() void {
    g_state.mutex.lockUncancelable(g_io);
    const reading = g_state.reading;
    const connected = g_state.connected;
    var pending_connection_announcement = false;
    var announce_connection = false;
    if (g_state.announce_connection and connected) {
        if (reading) |r| {
            pending_connection_announcement = true;
            announce_connection = canNotifyBatteryStatus(r);
        }
    }
    if (announce_connection) g_state.announce_connection = false;
    g_state.mutex.unlock(g_io);
    const paused = g_state.paused.load(.acquire);

    var icon_text: []const u8 = "--";
    var color: COLORREF = col_gray;
    var num_buf: [4]u8 = undefined;

    // Refresh each side's last-known snapshot from a live reading, and run the
    // notification logic. Tooltip + icon below render from the snapshots, so
    // they always show a real per-side value even while a half is asleep.
    // Level and status are kept independently: a sleeping half often answers
    // one field (e.g. level=100) while the other comes back empty/unknown, and
    // clobbering a real "charging" with that "?" is exactly the stale-status bug.
    if (!paused and connected and reading != null) {
        const r = reading.?;
        if (r.left.level != null) g_last_left.level = r.left.level;
        if (r.left.status != .unknown) g_last_left.status = r.left.status;
        if (r.right.level != null) g_last_right.level = r.right.level;
        if (r.right.status != .unknown) g_last_right.status = r.right.status;

        // Drive notifications from the merged snapshot, not the raw reading: a
        // charging side that momentarily reports an empty status would otherwise
        // look ".unknown" (i.e. "not charging") and fire a false low-battery
        // warning. The snapshot carries the last real status per side.
        const snapshot: battery.Reading = .{ .left = g_last_left, .right = g_last_right };
        if (announce_connection) {
            showBatteryStatusBalloon(snapshot);
            latchLowBatteryNotifications(snapshot);
        } else if (!pending_connection_announcement) {
            checkLowBattery(snapshot);
        }
    } else {
        g_state.notified_low = .{ false, false };
    }

    // Tooltip: last-known value for each side, in every state, with a short
    // header when the reading isn't live.
    {
        var lb: [40]u8 = undefined;
        var rb: [40]u8 = undefined;
        var tip_buf: [128]u8 = undefined;
        const header: []const u8 = if (paused)
            "Paused (port free for Bazecor):\n"
        else if (!connected)
            "Not connected — last known:\n"
        else
            "";
        const tip = std.fmt.bufPrint(&tip_buf, "{s}Left: {s}\nRight: {s}", .{
            header,
            fmtKnownSide(&lb, g_last_left),
            fmtKnownSide(&rb, g_last_right),
        }) catch "dygma-battery";
        setUtf16(g_nid.szTip[0..], tip);
    }

    // Icon: the lower of the two last-known side levels. Dim to gray while
    // offline or paused; "--" only before either side has ever reported.
    const live = connected and !paused;
    var disp_level: ?u8 = null;
    var disp_status: battery.Status = .unknown;
    if (g_last_left.level) |l| {
        disp_level = l;
        disp_status = g_last_left.status;
    }
    if (g_last_right.level) |rl| {
        if (disp_level == null or rl < disp_level.?) {
            disp_level = rl;
            disp_status = g_last_right.status;
        }
    }
    if (disp_level) |lvl| {
        icon_text = std.fmt.bufPrint(&num_buf, "{d}", .{lvl}) catch "?";
        color = if (!live)
            col_gray
        else if (disp_status == .charging)
            col_blue
        else if (lvl >= 50)
            col_green
        else if (lvl >= low_threshold)
            col_amber
        else
            col_red;
    }

    const new_icon = makeTextIcon(icon_text, color);
    const old_icon = g_nid.hIcon;
    g_nid.hIcon = new_icon;
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    if (old_icon) |icon| _ = DestroyIcon(icon);
}

/// Append a runtime-built string as a menu item. AppendMenuW needs a
/// null-terminated UTF-16 string, so convert into a local buffer first (same
/// conversion as setUtf16). AppendMenuW copies the text, so the buffer is
/// free to be reused after the call.
fn appendMenuText(menu: HMENU, flags: UINT, id: usize, text: []const u8) void {
    var wbuf: [64]u16 = undefined;
    const max = wbuf.len - 1;
    const src = if (text.len > max) text[0..max] else text;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0..max], src) catch 0;
    wbuf[n] = 0;
    _ = AppendMenuW(menu, flags, id, wbuf[0..n :0].ptr);
}

/// Menu form of a last-known side snapshot: "{d}% (Status)" with a capitalized
/// status word to match the menu styling; "no reading yet" if never reported.
/// Status.label() stays lowercase for the CLI/tooltip.
fn fmtMenuSide(buf: []u8, s: battery.SideReading) []const u8 {
    const lvl = s.level orelse return "no reading yet";
    const word = s.status.label();
    var cap: [16]u8 = undefined;
    const w = if (word.len > 0 and word.len <= cap.len) blk: {
        std.mem.copyForwards(u8, cap[0..word.len], word);
        cap[0] = std.ascii.toUpper(word[0]);
        break :blk cap[0..word.len];
    } else word;
    return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, w }) catch buf[0..0];
}

fn fmtSide(buf: []u8, s: battery.SideReading) []const u8 {
    if (s.level) |lvl| {
        return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, s.status.label() }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "?% ({s})", .{s.status.label()}) catch buf[0..0];
}

/// Tooltip form of a last-known side snapshot: the real value if the side has
/// ever reported, else a plain "no reading yet".
fn fmtKnownSide(buf: []u8, s: battery.SideReading) []const u8 {
    if (s.level) |lvl| {
        return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, s.status.label() }) catch buf[0..0];
    }
    return "no reading yet";
}

fn checkLowBattery(r: battery.Reading) void {
    const sides = [_]battery.SideReading{ r.left, r.right };
    const names = [_][]const u8{ "Left", "Right" };
    for (sides, 0..) |s, i| {
        if (s.status == .charging) {
            g_state.notified_low[i] = false;
            continue;
        }
        const lvl = s.level orelse continue;
        if (lvl < low_threshold) {
            if (!g_state.notified_low[i]) {
                g_state.notified_low[i] = true;
                var tb: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&tb, "{s} side at {d}%", .{ names[i], lvl }) catch "battery low";
                showBalloon(notification_title_low, text, NIIF_WARNING);
            }
        } else {
            g_state.notified_low[i] = false;
        }
    }
}

fn latchLowBatteryNotifications(r: battery.Reading) void {
    const sides = [_]battery.SideReading{ r.left, r.right };
    for (sides, 0..) |s, i| {
        if (s.status == .charging) {
            g_state.notified_low[i] = false;
            continue;
        }
        const lvl = s.level orelse {
            g_state.notified_low[i] = false;
            continue;
        };
        g_state.notified_low[i] = lvl < low_threshold;
    }
}

fn showBatteryStatusBalloon(r: battery.Reading) void {
    var lb: [32]u8 = undefined;
    var rb: [32]u8 = undefined;
    var text_buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Left: {s}\nRight: {s}", .{
        fmtSide(&lb, r.left),
        fmtSide(&rb, r.right),
    }) catch "Battery status available";
    const flags: DWORD = if (hasLowBattery(r)) NIIF_WARNING else NIIF_INFO_ICON;
    showBalloon(notification_title_battery, text, flags);
}

fn canNotifyBatteryStatus(r: battery.Reading) bool {
    return r.left.level != null and r.right.level != null;
}

fn hasLowBattery(r: battery.Reading) bool {
    const sides = [_]battery.SideReading{ r.left, r.right };
    for (sides) |s| {
        if (s.status == .charging) continue;
        const lvl = s.level orelse continue;
        if (lvl < low_threshold) return true;
    }
    return false;
}

fn showBalloon(title: []const u8, text: []const u8, flags: DWORD) void {
    setUtf16(g_nid.szInfoTitle[0..], title);
    setUtf16(g_nid.szInfo[0..], text);
    g_nid.dwInfoFlags = flags;
    g_nid.uFlags = NIF_INFO;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP; // restore for the next icon/tip update
}

/// Render `text` centered on a solid `color` 16x16 icon. Caller owns the
/// returned HICON (DestroyIcon). Returns null on any GDI failure.
fn makeTextIcon(text: []const u8, color: COLORREF) ?HICON {
    const screen = GetDC(null) orelse return null;
    defer _ = ReleaseDC(null, screen);
    const mdc = CreateCompatibleDC(screen) orelse return null;
    defer _ = DeleteDC(mdc);

    const color_bmp = CreateCompatibleBitmap(screen, icon_size, icon_size) orelse return null;
    defer _ = DeleteObject(@ptrCast(color_bmp));
    // Monochrome AND mask, all zero == fully opaque color icon.
    const mask_bits = [_]u8{0} ** 32;
    const mask_bmp = CreateBitmap(icon_size, icon_size, 1, 1, &mask_bits) orelse return null;
    defer _ = DeleteObject(@ptrCast(mask_bmp));

    const prev_bmp = SelectObject(mdc, @ptrCast(color_bmp)) orelse return null;

    var rect = RECT{ .left = 0, .top = 0, .right = icon_size, .bottom = icon_size };
    if (CreateSolidBrush(color)) |brush| {
        _ = FillRect(mdc, &rect, brush);
        _ = DeleteObject(@ptrCast(brush));
    }

    const font = CreateFontW(-13, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, 0, 0, null);
    const prev_font = if (font) |f| SelectObject(mdc, @ptrCast(f)) else null;
    _ = SetBkMode(mdc, TRANSPARENT);
    _ = SetTextColor(mdc, col_text);

    var wbuf: [8]u16 = undefined;
    const wn = std.unicode.utf8ToUtf16Le(wbuf[0..7], text) catch 0;
    _ = DrawTextW(mdc, &wbuf, @intCast(wn), &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);

    if (font) |f| {
        if (prev_font) |pf| _ = SelectObject(mdc, pf);
        _ = DeleteObject(@ptrCast(f));
    }
    _ = SelectObject(mdc, prev_bmp); // deselect color_bmp before CreateIconIndirect reads it

    var ii = ICONINFO{
        .fIcon = .TRUE,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask_bmp,
        .hbmColor = color_bmp,
    };
    return CreateIconIndirect(&ii);
}

/// Write `s` (assumed ASCII) as a null-terminated UTF-16 string into `dst`.
fn setUtf16(dst: []u16, s: []const u8) void {
    const max = dst.len - 1;
    const src = if (s.len > max) s[0..max] else s;
    const n = std.unicode.utf8ToUtf16Le(dst[0..max], src) catch 0;
    dst[n] = 0;
}

// ---------------------------------------------------------------------------
// Background polling thread: owns the serial connection.
// ---------------------------------------------------------------------------
fn pollLoop(ctx: *PollCtx) void {
    const io = ctx.io;
    const st = ctx.state;

    while (!st.stop.load(.acquire)) {
        // PAUSED: hold no port so Bazecor can use it; idle until resumed.
        if (st.paused.load(.acquire)) {
            setConnected(ctx, false);
            sleepMs(io, st, 300);
            continue;
        }

        // DISCOVER
        const path = (device.findDygmaPort(io, ctx.gpa) catch null) orelse {
            setConnected(ctx, false);
            sleepMs(io, st, 3000);
            continue;
        };
        defer ctx.gpa.free(path);

        // CONNECT
        var dev = focus.Focus.open(io, path) catch {
            setConnected(ctx, false);
            sleepMs(io, st, 3000);
            continue;
        };
        defer dev.close();

        // POLL. No forceRead on connect: the neuron serves cached values on a
        // plain read, and forcing a re-poll every cycle blanks them mid-refresh
        // (empty "?"/no-reading responses). forceRead runs only when the user
        // asks to refresh (below). Mirrors the Go tray's pollLoop.
        while (!st.stop.load(.acquire)) {
            // User asked to release the port: close and drop back to idle.
            if (st.paused.load(.acquire)) {
                setConnected(ctx, false);
                break;
            }
            const r = battery.read(&dev) catch {
                setConnected(ctx, false);
                break;
            };
            st.mutex.lockUncancelable(g_io);
            const announce_connection = !st.connected;
            st.reading = r;
            st.connected = true;
            if (announce_connection) st.announce_connection = true;
            st.mutex.unlock(g_io);
            _ = PostMessageW(ctx.hwnd, WM_BATTERY_UPDATE, 0, 0);

            // Wait out the interval, staying responsive to stop/refresh/pause.
            // A user refresh (menu "Refresh battery now" or double-click) wakes
            // us early: forceRead to re-poll the sides over RF, let it settle,
            // then loop to re-read the freshly-updated cached values.
            const refreshed = waitForNextPoll(io, st, poll_interval_ms);
            if (refreshed) {
                battery.forceRead(&dev);
                sleepMs(io, st, battery.force_read_settle_s * 1000);
            }
        }
    }
}

fn setConnected(ctx: *PollCtx, connected: bool) void {
    const st = ctx.state;
    st.mutex.lockUncancelable(g_io);
    const changed = st.connected != connected;
    st.connected = connected;
    if (!connected) {
        st.reading = null;
        st.announce_connection = false;
    }
    st.mutex.unlock(g_io);
    if (changed) _ = PostMessageW(ctx.hwnd, WM_BATTERY_UPDATE, 0, 0);
}

fn sleepMs(io: std.Io, st: *State, ms: u64) void {
    if (st.stop.load(.acquire)) return;
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
    };
    dur.sleep(io) catch {};
}

/// Sleep out the poll interval, waking early on stop/pause/refresh. Returns
/// true only when a user refresh triggered the early wake, so the caller can
/// forceRead before the next read (stop/pause return false).
fn waitForNextPoll(io: std.Io, st: *State, interval_ms: u64) bool {
    var waited: u64 = 0;
    const quantum_ms: u64 = 1000;
    while (waited < interval_ms) {
        if (st.stop.load(.acquire)) return false;
        if (st.paused.load(.acquire)) return false;
        if (st.refresh.swap(false, .acq_rel)) return true;
        const remaining = interval_ms - waited;
        const sleep_ms = @min(remaining, quantum_ms);
        sleepMs(io, st, sleep_ms);
        waited += sleep_ms;
    }
    return false;
}

comptime {
    if (builtin.os.tag != .windows) @compileError("tray.zig is Windows-only");
}
