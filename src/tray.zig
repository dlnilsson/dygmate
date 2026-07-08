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
const NOTIFYICON_VERSION_4: UINT = 4;
const NIIF_WARNING: DWORD = 0x02;

const MF_STRING: UINT = 0x0000;
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

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("DygmaBatteryTrayWnd");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("dygma-battery");
const menu_refresh = std.unicode.utf8ToUtf16LeStringLiteral("Refresh now");
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

// Last-known-good icon value (UI thread only). The wireless halves sleep and
// briefly report a null level; rather than flicker the icon to "--", we keep
// showing the last real percentage while still connected. Cleared on
// disconnect so a truly-gone keyboard does show "--".
var g_last_level: ?u8 = null;
var g_last_status: battery.Status = .unknown;

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
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = makeTextIcon("--", col_gray);
    setUtf16(g_nid.szTip[0..], "dygma-battery: starting\u{2026}");
    _ = Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_nid.uVersion = NOTIFYICON_VERSION_4;
    _ = Shell_NotifyIconW(NIM_SETVERSION, &g_nid);

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
    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_REFRESH), menu_refresh);
    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_TOGGLE), if (paused) menu_reconnect else menu_disconnect);
    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_QUIT), menu_quit);

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
    g_state.mutex.unlock(g_io);
    const paused = g_state.paused.load(.acquire);

    var icon_text: []const u8 = "--";
    var color: COLORREF = col_gray;
    var num_buf: [4]u8 = undefined;

    if (paused) {
        // Port released for Bazecor: keep showing the last known percentage.
        var tip_buf: [80]u8 = undefined;
        const tip = if (g_last_level) |lvl|
            (std.fmt.bufPrint(&tip_buf, "dygma-battery: paused — port free for Bazecor (last known {d}%)", .{lvl}) catch "dygma-battery: paused — port free for Bazecor")
        else
            "dygma-battery: paused — port free for Bazecor";
        setUtf16(g_nid.szTip[0..], tip);
        g_state.notified_low = .{ false, false };
    } else if (connected and reading != null) {
        const r = reading.?;
        // Display the lower of the two valid side levels — the one at risk.
        var disp_level: ?u8 = null;
        var disp_status: battery.Status = .unknown;
        if (r.left.level) |ll| {
            disp_level = ll;
            disp_status = r.left.status;
        }
        if (r.right.level) |rl| {
            if (disp_level == null or rl < disp_level.?) {
                disp_level = rl;
                disp_status = r.right.status;
            }
        }
        // Remember the latest real reading. A side often briefly sleeps and
        // reports null; we keep showing the last known value, never a blank.
        if (disp_level) |lvl| {
            g_last_level = lvl;
            g_last_status = disp_status;
        }

        var lb: [32]u8 = undefined;
        var rb: [32]u8 = undefined;
        var tip_buf: [96]u8 = undefined;
        const tip = std.fmt.bufPrint(&tip_buf, "Left: {s}\nRight: {s}", .{
            fmtSide(&lb, r.left),
            fmtSide(&rb, r.right),
        }) catch "dygma-battery";
        setUtf16(g_nid.szTip[0..], tip);

        checkLowBattery(r);
    } else {
        // Disconnected: keep displaying the last known percentage (the battery
        // hasn't changed) — just flag the offline state in the tooltip.
        var tip_buf: [64]u8 = undefined;
        const tip = if (g_last_level) |lvl|
            (std.fmt.bufPrint(&tip_buf, "dygma-battery: not connected (last known {d}%)", .{lvl}) catch "dygma-battery: not connected")
        else
            "dygma-battery: not connected";
        setUtf16(g_nid.szTip[0..], tip);
        g_state.notified_low = .{ false, false };
    }

    // Render from the last known level. Dim to gray while offline or paused so
    // a stale value reads as such; "--" shows only before the first reading.
    const live = connected and !paused;
    if (g_last_level) |lvl| {
        icon_text = std.fmt.bufPrint(&num_buf, "{d}", .{lvl}) catch "?";
        color = if (!live)
            col_gray
        else if (g_last_status == .charging)
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
    g_nid.uFlags = NIF_ICON | NIF_TIP;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    if (old_icon) |icon| _ = DestroyIcon(icon);
}

fn fmtSide(buf: []u8, s: battery.SideReading) []const u8 {
    if (s.level) |lvl| {
        return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, s.status.label() }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "?% ({s})", .{s.status.label()}) catch buf[0..0];
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
                showBalloon("Dygma battery low", text);
            }
        } else {
            g_state.notified_low[i] = false;
        }
    }
}

fn showBalloon(title: []const u8, text: []const u8) void {
    setUtf16(g_nid.szInfoTitle[0..], title);
    setUtf16(g_nid.szInfo[0..], text);
    g_nid.dwInfoFlags = NIIF_WARNING;
    g_nid.uFlags = NIF_INFO;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    g_nid.uFlags = NIF_ICON | NIF_TIP; // restore for the next icon/tip update
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

        // PRIME
        var prime_buf: [64]u8 = undefined;
        _ = dev.request("wireless.battery.forceRead", &prime_buf) catch {};
        sleepMs(io, st, battery.force_read_settle_s * 1000);

        // POLL
        while (!st.stop.load(.acquire)) {
            // User asked to release the port: close and drop back to idle.
            if (st.paused.load(.acquire)) {
                dev.close();
                setConnected(ctx, false);
                break;
            }
            const r = battery.readAll(&dev) catch {
                dev.close();
                setConnected(ctx, false);
                break;
            };
            // Both sides asleep -> nudge the neuron to refresh before the next
            // poll. forceRead is an argument-less command (a read, not a flash
            // setter), so it is safe to repeat.
            if (r.left.level == null and r.right.level == null) {
                _ = dev.request("wireless.battery.forceRead", &prime_buf) catch {};
            }
            st.mutex.lockUncancelable(g_io);
            st.reading = r;
            st.connected = true;
            st.mutex.unlock(g_io);
            _ = PostMessageW(ctx.hwnd, WM_BATTERY_UPDATE, 0, 0);

            // Wait out the interval, but stay responsive to stop/refresh.
            waitForNextPoll(io, st, battery.suggestedPollIntervalSeconds(r) * 1000);
        }
    }
}

fn setConnected(ctx: *PollCtx, connected: bool) void {
    const st = ctx.state;
    st.mutex.lockUncancelable(g_io);
    const changed = st.connected != connected;
    st.connected = connected;
    if (!connected) st.reading = null;
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

fn waitForNextPoll(io: std.Io, st: *State, interval_ms: u64) void {
    var waited: u64 = 0;
    const quantum_ms: u64 = 1000;
    while (waited < interval_ms) {
        if (st.stop.load(.acquire)) break;
        if (st.paused.load(.acquire)) break;
        if (st.refresh.swap(false, .acq_rel)) break;
        const remaining = interval_ms - waited;
        const sleep_ms = @min(remaining, quantum_ms);
        sleepMs(io, st, sleep_ms);
        waited += sleep_ms;
    }
}

comptime {
    if (builtin.os.tag != .windows) @compileError("tray.zig is Windows-only");
}
