//! Windows system-tray battery indicator for Dygma wireless keyboards.
//!
//! A hidden window owns a Shell_NotifyIcon tray icon; a background thread
//! owns the Focus serial connection and runs the same discover -> connect ->
//! poll loop as the CLI, waking the UI thread with PostMessageW on every new
//! reading. The icon shows the *lower* of the two sides' battery percentage;
//! the tooltip carries the full both-sides detail. Windows only.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const focus = @import("focus.zig");
const battery = @import("battery.zig");
const layer = @import("layer.zig");
const device = @import("device.zig");
const common = @import("tray_common.zig");
const config = @import("config.zig");
const update = @import("update.zig");
const statusserver = @import("statusserver.zig");
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
const GUID = windows.GUID;
const HWND = windows.HWND;
const HICON = windows.HICON;
const HMENU = windows.HMENU;
const HINSTANCE = windows.HINSTANCE;
const ATOM = windows.ATOM;
const HDC = *opaque {};
const HBITMAP = *opaque {};
const HFONT = *opaque {};
const HBRUSH = *opaque {};
const HPEN = *opaque {};
const HCURSOR = HICON;
const HGDIOBJ = *anyopaque;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

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
extern "kernel32" fn GetModuleFileNameW(hModule: ?HINSTANCE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
// --version support: this is a GUI-subsystem exe with no console of its own, so
// borrow the parent console (if any) and write straight to its stdout handle.
extern "kernel32" fn AttachConsole(dwProcessId: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
// Opens the release page in the default browser for the update menu item.
extern "shell32" fn ShellExecuteW(hwnd: ?HWND, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16, lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: i32) callconv(.winapi) ?windows.HINSTANCE;

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
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
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
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: COLORREF, bAlpha: u8, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "user32" fn SystemParametersInfoW(uiAction: UINT, uiParam: UINT, pvParam: ?*anyopaque, fWinIni: UINT) callconv(.winapi) BOOL;

extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: i32, cy: i32) callconv(.winapi) ?HBITMAP;
extern "gdi32" fn CreateBitmap(nWidth: i32, nHeight: i32, nPlanes: UINT, nBitCount: UINT, lpBits: ?*const anyopaque) callconv(.winapi) ?HBITMAP;
extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetPixelV(hdc: HDC, x: i32, y: i32, color: COLORREF) callconv(.winapi) BOOL;
extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
extern "gdi32" fn CreatePen(iStyle: i32, cWidth: i32, color: COLORREF) callconv(.winapi) ?HPEN;
extern "gdi32" fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(.winapi) BOOL;
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
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(AppID: [*:0]const u16) callconv(.winapi) i32; // HRESULT

extern "advapi32" fn RegCreateKeyExW(hKey: windows.HKEY, lpSubKey: [*:0]const u16, Reserved: DWORD, lpClass: ?[*:0]const u16, dwOptions: DWORD, samDesired: DWORD, lpSecurityAttributes: ?*anyopaque, phkResult: *windows.HKEY, lpdwDisposition: ?*DWORD) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(hKey: windows.HKEY, lpValueName: ?[*:0]const u16, Reserved: DWORD, dwType: DWORD, lpData: [*]const u8, cbData: DWORD) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(hKey: windows.HKEY) callconv(.winapi) i32;

// ---------------------------------------------------------------------------
// COM plumbing for the Start Menu shortcut. Explorer only attributes legacy
// Shell_NotifyIcon toasts to our AUMID when a Start Menu .lnk carries the
// same System.AppUserModel.ID shell property; the AppUserModelId registry
// DisplayName alone is not consulted for balloon notifications.
// ---------------------------------------------------------------------------
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: DWORD, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn PropVariantClear(pvar: *PROPVARIANT) callconv(.winapi) i32;
extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, dwFlags: DWORD, hToken: ?*anyopaque, ppszPath: *?[*:0]u16) callconv(.winapi) i32;

const PROPERTYKEY = extern struct { fmtid: GUID, pid: DWORD };

// x64 PROPVARIANT is 24 bytes: 8-byte vt header + 16-byte value union
// (largest members are {ULONG, void*} counted-array pairs).
const PROPVARIANT = extern struct {
    vt: u16,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    data: extern union { pwszVal: ?[*:0]const u16, raw: [2]u64 },
};

const IShellLinkW = extern struct {
    v: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*IShellLinkW) callconv(.winapi) u32,
        Release: *const fn (*IShellLinkW) callconv(.winapi) u32,
        GetPath: *const fn (*IShellLinkW, [*]u16, i32, ?*anyopaque, DWORD) callconv(.winapi) i32,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const anyopaque,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const anyopaque,
        GetArguments: *const anyopaque,
        SetArguments: *const anyopaque,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const anyopaque,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) i32,
    };
};

const IPersistFile = extern struct {
    v: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*IPersistFile, *const GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*IPersistFile) callconv(.winapi) u32,
        Release: *const fn (*IPersistFile) callconv(.winapi) u32,
        GetClassID: *const anyopaque,
        IsDirty: *const anyopaque,
        Load: *const fn (*IPersistFile, [*:0]const u16, DWORD) callconv(.winapi) i32,
        Save: *const fn (*IPersistFile, ?[*:0]const u16, BOOL) callconv(.winapi) i32,
        SaveCompleted: *const anyopaque,
        GetCurFile: *const anyopaque,
    };
};

const IPropertyStore = extern struct {
    v: *const VTable,
    const VTable = extern struct {
        QueryInterface: *const fn (*IPropertyStore, *const GUID, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*IPropertyStore) callconv(.winapi) u32,
        Release: *const fn (*IPropertyStore) callconv(.winapi) u32,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        GetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *PROPVARIANT) callconv(.winapi) i32,
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) i32,
        Commit: *const fn (*IPropertyStore) callconv(.winapi) i32,
    };
};

const CLSID_ShellLink = GUID.parse("{00021401-0000-0000-C000-000000000046}");
const IID_IShellLinkW = GUID.parse("{000214F9-0000-0000-C000-000000000046}");
const IID_IPersistFile = GUID.parse("{0000010B-0000-0000-C000-000000000046}");
const IID_IPropertyStore = GUID.parse("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}");
const FOLDERID_Programs = GUID.parse("{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}");
const PKEY_AppUserModel_ID = PROPERTYKEY{ .fmtid = GUID.parse("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"), .pid = 5 };

const VT_LPWSTR: u16 = 31;
const CLSCTX_INPROC_SERVER: DWORD = 1;
const COINIT_APARTMENTTHREADED: DWORD = 2;
const STGM_READ: DWORD = 0;

// ---------------------------------------------------------------------------
// Win32 constants.
// ---------------------------------------------------------------------------
const WM_APP = 0x8000;
const WM_TRAYICON: UINT = WM_APP + 1;
const WM_BATTERY_UPDATE: UINT = WM_APP + 2;
const WM_NULL: UINT = 0x0000;
const WM_DESTROY: UINT = 0x0002;
const WM_PAINT: UINT = 0x000F;
const WM_TIMER: UINT = 0x0113;
const WM_CONTEXTMENU: u16 = 0x007B;
const WM_RBUTTONUP: u16 = 0x0205;
const WM_LBUTTONDBLCLK: u16 = 0x0203;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_MOUSEACTIVATE: UINT = 0x0021;

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
const MF_CHECKED: UINT = 0x0008; // checkmark next to the item
const MF_SEPARATOR: UINT = 0x0800;
const MF_BYCOMMAND: UINT = 0x0000;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_RETURNCMD: UINT = 0x0100;

const DT_CENTER: UINT = 0x01;
const DT_VCENTER: UINT = 0x04;
const DT_SINGLELINE: UINT = 0x20;
const DT_NOCLIP: UINT = 0x100;
const TRANSPARENT: i32 = 1;
const WS_POPUP: DWORD = 0x80000000;
const WS_OVERLAPPED: DWORD = 0x00000000;
const WS_EX_TOPMOST: DWORD = 0x00000008;
const WS_EX_TRANSPARENT: DWORD = 0x00000020;
const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
const WS_EX_LAYERED: DWORD = 0x00080000;
const WS_EX_NOACTIVATE: DWORD = 0x08000000;
const LWA_COLORKEY: DWORD = 0x00000001;
const LWA_ALPHA: DWORD = 0x00000002;
const SW_HIDE: i32 = 0;
const SW_SHOWNORMAL: i32 = 1;
const SW_SHOWNOACTIVATE: i32 = 4;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_SHOWWINDOW: UINT = 0x0040;
const SPI_GETWORKAREA: UINT = 0x0030;
const HWND_TOPMOST: HWND = @ptrFromInt(std.math.maxInt(usize));
const HTTRANSPARENT: LRESULT = -1;
const MA_NOACTIVATE: LRESULT = 3;
const IDC_ARROW: usize = 32512;
const DEFAULT_CHARSET: DWORD = 1;
const FW_BOLD: i32 = 700;
const CLEARTYPE_QUALITY: DWORD = 5;
const PS_SOLID: i32 = 0;

const ID_REFRESH: i32 = 1;
const ID_QUIT: i32 = 2;
const ID_TOGGLE: i32 = 3;
const ID_OSD_TOGGLE: i32 = 4;
const ID_UPDATE: i32 = 5;
const ID_OSD_HIDE: usize = 1;
const ID_OSD_SHOW: usize = 2;

const icon_size: i32 = 16;
const osd_width: i32 = 156;
const osd_height: i32 = 56;
const osd_bottom_margin: i32 = 124;
const osd_alpha: u8 = 250;
const osd_corner_diameter: i32 = 26;

// Status colors, COLORREF (0x00BBGGRR).
fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}
fn toColorRef(c: common.Rgb) COLORREF {
    return rgb(c.r, c.g, c.b);
}
const col_gray = toColorRef(common.palette.gray);
const col_osd_transparent = rgb(255, 0, 255);
const col_osd_bg = rgb(18, 20, 24);
const col_osd_border = rgb(92, 101, 116);
const col_text = rgb(255, 255, 255);

const HKEY_CURRENT_USER: windows.HKEY = @ptrFromInt(0x80000001);
const REG_SZ: DWORD = 1;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const KEY_SET_VALUE: DWORD = 0x0002;

const ERROR_ALREADY_EXISTS: DWORD = 183;
const singleton_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\DygmaBatteryTraySingleton");

// Explicit AppUserModelID: without one, Windows attributes our balloon toasts
// to a synthesized "Microsoft.Explorer.Notification.{hash}" sender.
const aumid = std.unicode.utf8ToUtf16LeStringLiteral("dlnilsson.dygmate.tray");
const aumid_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\AppUserModelId\\dlnilsson.dygmate.tray");
const aumid_display_name = std.unicode.utf8ToUtf16LeStringLiteral("dygmate");
const reg_value_display_name = std.unicode.utf8ToUtf16LeStringLiteral("DisplayName");
const lnk_name = std.unicode.utf8ToUtf16LeStringLiteral("\\dygmate.lnk");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("DygmaBatteryTrayWnd");
const osd_class_name = std.unicode.utf8ToUtf16LeStringLiteral("DygmaBatteryOsdWnd");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("dygmate");
const osd_window_title = std.unicode.utf8ToUtf16LeStringLiteral("dygma layer");
const menu_refresh = std.unicode.utf8ToUtf16LeStringLiteral("Refresh battery now");
const menu_disconnect = std.unicode.utf8ToUtf16LeStringLiteral("Disconnect (release port for Bazecor)");
const menu_reconnect = std.unicode.utf8ToUtf16LeStringLiteral("Reconnect");
const menu_osd = std.unicode.utf8ToUtf16LeStringLiteral("Show layer overlay");
const menu_quit = std.unicode.utf8ToUtf16LeStringLiteral("Quit");
const menu_version = std.unicode.utf8ToUtf16LeStringLiteral("Version: dygmate " ++ build_options.version);

// ---------------------------------------------------------------------------
// Shared state between the UI thread and the polling thread. Defined in
// tray_common.zig so tray_linux.zig shares it.
// ---------------------------------------------------------------------------
const State = common.State;

const PollCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    hwnd: HWND,
    state: *State,
};

var g_state: State = .{};
var g_nid: NOTIFYICONDATAW = undefined;
var g_osd_hwnd: ?HWND = null;
var g_osd_text: [32]u16 = [_]u16{0} ** 32;
var g_osd_text_len: usize = 0;
/// The process Io, shared by the UI and polling threads (Threaded io is
/// thread-safe). Stashed globally so the UI thread can lock the state mutex.
var g_io: std.Io = undefined;
/// Allocator, shared with the UI thread for the best-effort config save.
var g_gpa: std.mem.Allocator = undefined;
/// Config file path, resolved once at startup so the window callback (which has
/// no environ) can persist toggles. Null if the path could not be built.
var g_config_path: ?[]const u8 = null;
/// Persisted settings, loaded once at startup. Kept whole so toggling one field
/// and saving does not clobber the user's other hand-edited values.
var g_cfg: config.Config = .{};
/// Populated by the one-shot GitHub update check ~60s after startup. Read on
/// the UI thread when building the tray menu.
var g_update: update.State = .{};

// Last-known-good reading, per side (UI thread only). See common.LastKnown.
var g_last: common.LastKnown = .{};
/// Per side: awaiting authoritative forceRead verification (UI thread only;
/// snapshotted from State by updateTray, read by the menu builder).
var g_unverified: [2]bool = .{ false, false };

/// Write the version to the parent console's stdout. No-op-ish if launched
/// without a console (e.g. from Explorer): AttachConsole simply fails and the
/// handle is invalid, so nothing is printed and the process still exits 0.
fn printVersion() void {
    const attach_parent_process: DWORD = 0xFFFFFFFF; // ATTACH_PARENT_PROCESS
    const std_output_handle: DWORD = @bitCast(@as(i32, -11)); // STD_OUTPUT_HANDLE
    _ = AttachConsole(attach_parent_process);
    const h = GetStdHandle(std_output_handle) orelse return;
    const line = "dygmate-tray " ++ build_options.version ++ "\r\n";
    _ = WriteFile(h, line.ptr, line.len, null, null);
}

/// Best-effort: register the AUMID display name so Windows 11 toast headers
/// show "dygmate" instead of "Microsoft.Explorer.Notification.{hash}".
/// Failures are ignored — notifications still work, just with the ugly header.
/// The key is left behind on exit: deleting it would drop the app's entry
/// (and the user's preferences) under Settings > Notifications, and a winget
/// portable uninstall won't clean it up either — it's per-user and tiny.
fn registerAumid() void {
    var key: windows.HKEY = undefined;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, aumid_key, 0, null, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, null, &key, null) != 0) return;
    defer _ = RegCloseKey(key);
    const bytes: DWORD = (aumid_display_name.len + 1) * 2; // UTF-16 incl. NUL
    _ = RegSetValueExW(key, reg_value_display_name, 0, REG_SZ, @ptrCast(aumid_display_name), bytes);
}

/// Best-effort: create (or repair) a Start Menu shortcut carrying our AUMID
/// as its System.AppUserModel.ID property. This is what actually makes
/// Explorer show "dygmate" as the toast header -- registerAumid()'s registry
/// DisplayName only covers the Settings > Notifications sender list. The
/// shortcut is left behind on exit for the same reasons as the registry key
/// (and so the header survives across sessions); winget portable uninstall
/// won't remove it.
fn ensureStartMenuShortcut() void {
    var exe_buf: [1024]u16 = undefined;
    const exe_len = GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (exe_len == 0 or exe_len >= exe_buf.len - 1) return;
    exe_buf[exe_len] = 0;
    const exe_path = exe_buf[0..exe_len :0];

    var folder: ?[*:0]u16 = null;
    if (SHGetKnownFolderPath(&FOLDERID_Programs, 0, null, &folder) != 0) return;
    defer CoTaskMemFree(folder);
    const folder_path = std.mem.span(folder.?);

    var lnk_buf: [1024:0]u16 = undefined;
    if (folder_path.len + lnk_name.len >= lnk_buf.len) return;
    @memcpy(lnk_buf[0..folder_path.len], folder_path);
    @memcpy(lnk_buf[folder_path.len..][0..lnk_name.len], lnk_name);
    lnk_buf[folder_path.len + lnk_name.len] = 0;
    const lnk_path = lnk_buf[0 .. folder_path.len + lnk_name.len :0];

    const co = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (co < 0) return; // S_OK (0) or S_FALSE (1): both need CoUninitialize
    defer CoUninitialize();

    var link_raw: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &link_raw) != 0) return;
    const link: *IShellLinkW = @ptrCast(@alignCast(link_raw.?));
    defer _ = link.v.Release(link);

    var pf_raw: ?*anyopaque = null;
    if (link.v.QueryInterface(link, &IID_IPersistFile, &pf_raw) != 0) return;
    const pf: *IPersistFile = @ptrCast(@alignCast(pf_raw.?));
    defer _ = pf.v.Release(pf);

    var ps_raw: ?*anyopaque = null;
    if (link.v.QueryInterface(link, &IID_IPropertyStore, &ps_raw) != 0) return;
    const ps: *IPropertyStore = @ptrCast(@alignCast(ps_raw.?));
    defer _ = ps.v.Release(ps);

    // Skip the write when an up-to-date shortcut already exists.
    if (pf.v.Load(pf, lnk_path, STGM_READ) == 0) {
        var cur_path: [1024]u16 = undefined;
        const path_ok = link.v.GetPath(link, &cur_path, cur_path.len, null, 0) == 0 and
            std.mem.eql(u16, std.mem.sliceTo(&cur_path, 0), exe_path);
        var pv = PROPVARIANT{ .vt = 0, .data = .{ .raw = .{ 0, 0 } } };
        const aumid_ok = ps.v.GetValue(ps, &PKEY_AppUserModel_ID, &pv) == 0 and
            pv.vt == VT_LPWSTR and pv.data.pwszVal != null and
            std.mem.eql(u16, std.mem.span(pv.data.pwszVal.?), aumid);
        _ = PropVariantClear(&pv);
        if (path_ok and aumid_ok) return;
    }

    if (link.v.SetPath(link, exe_path) != 0) return;
    var pv = PROPVARIANT{ .vt = VT_LPWSTR, .data = .{ .pwszVal = aumid } };
    if (ps.v.SetValue(ps, &PKEY_AppUserModel_ID, &pv) < 0) return;
    if (ps.v.Commit(ps) < 0) return;
    _ = pf.v.Save(pf, lnk_path, .TRUE);
}

pub fn main(init: std.process.Init) void {
    g_io = init.io;
    g_gpa = init.gpa;

    if (init.minimal.args.toSlice(init.arena.allocator())) |args| {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            }
        }
    } else |_| {}

    // Resolve the config path once (leaked for the process lifetime) and restore
    // the saved "Show layer overlay" preference before the tray goes live.
    g_config_path = config.path(init.gpa, init.environ_map) catch null;
    if (g_config_path) |p| {
        g_cfg = config.loadOrInitFrom(init.io, init.gpa, p);
        g_state.osd_enabled.store(g_cfg.show_layer_overlay, .release);
    }

    // Single instance only: a second copy could never open the exclusive COM
    // port anyway, and would just show a confusing duplicate "--" icon. The
    // mutex handle is intentionally leaked — the OS frees it when we exit.
    _ = CreateMutexW(null, .FALSE, singleton_name);
    if (GetLastError() == ERROR_ALREADY_EXISTS) return;

    // Must run before any window/tray creation so notifications are
    // attributed to our AUMID instead of a synthesized Explorer one.
    registerAumid();
    ensureStartMenuShortcut();
    _ = SetCurrentProcessExplicitAppUserModelID(aumid);

    const hinst = GetModuleHandleW(null).?;

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW));
    wc.lpszClassName = class_name;
    _ = RegisterClassExW(&wc);

    var osd_wc = std.mem.zeroes(WNDCLASSEXW);
    osd_wc.cbSize = @sizeOf(WNDCLASSEXW);
    osd_wc.lpfnWndProc = osdWndProc;
    osd_wc.hInstance = hinst;
    osd_wc.hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW));
    osd_wc.lpszClassName = osd_class_name;
    _ = RegisterClassExW(&osd_wc);

    // A normal (never-shown) window rather than message-only, so
    // SetForegroundWindow works and the context menu dismisses on click-away.
    const hwnd = CreateWindowExW(0, class_name, window_title, WS_OVERLAPPED, 0, 0, 0, 0, null, null, hinst, null) orelse return;
    g_osd_hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
        osd_class_name,
        osd_window_title,
        WS_POPUP,
        0,
        0,
        osd_width,
        osd_height,
        hwnd,
        null,
        hinst,
        null,
    );
    if (g_osd_hwnd) |osd| _ = SetLayeredWindowAttributes(osd, col_osd_transparent, osd_alpha, LWA_ALPHA | LWA_COLORKEY);

    g_nid = std.mem.zeroes(NOTIFYICONDATAW);
    g_nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    g_nid.hWnd = hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = makeTextIcon("?", col_gray, null);
    setUtf16(g_nid.szTip[0..], "No keyboard discovered - last known:\nLeft: no reading yet\nRight: no reading yet");
    _ = Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_nid.uVersion = NOTIFYICON_VERSION_4;
    _ = Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
    g_nid.uFlags = NIF_TIP | NIF_SHOWTIP;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    // Battery status IPC for external status bars (\\.\pipe\dygmate) plus the
    // debug events feed. Started before the poll thread so the Focus wire-tap
    // and emit io are visible to it via the spawn happens-before barrier.
    statusserver.start(init.io, init.gpa, .{});

    var ctx = PollCtx{ .io = init.io, .gpa = init.gpa, .hwnd = hwnd, .state = &g_state };
    const thread = std.Thread.spawn(.{}, pollLoop, .{&ctx}) catch {
        statusserver.stop();
        _ = Shell_NotifyIconW(NIM_DELETE, &g_nid);
        return;
    };

    // One-shot GitHub update check on its own thread + isolated io.
    update.spawnCheck(init.gpa, build_options.version, &g_update);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    g_state.stop.store(true, .release);
    statusserver.stop();
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
            drainLayerChanges();
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

fn osdWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_PAINT => {
            paintOsd(hwnd);
            return 0;
        },
        WM_TIMER => {
            if (wparam == ID_OSD_HIDE) {
                _ = KillTimer(hwnd, ID_OSD_HIDE);
                _ = ShowWindow(hwnd, SW_HIDE);
            } else if (wparam == ID_OSD_SHOW) {
                _ = KillTimer(hwnd, ID_OSD_SHOW);
                presentOsd(hwnd);
            }
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_MOUSEACTIVATE => return MA_NOACTIVATE,
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn showMenu(hwnd: HWND) void {
    const paused = g_state.paused.load(.acquire);
    const menu = CreatePopupMenu() orelse return;
    defer _ = DestroyMenu(menu);

    // Informational (grayed, non-clickable) status header, mirroring the
    // tooltip: connection state + last-known level per side. g_last_* are
    // UI-thread-only, so no lock is needed for them; status needs the mutex.
    g_state.mutex.lockUncancelable(g_io);
    const status = g_state.status;
    const model = g_state.model;
    g_state.mutex.unlock(g_io);

    const conn_text = common.menuHeader(status, paused);
    const one_sided = if (model) |m| m.sides() < 2 else false;

    var lb: [48]u8 = undefined;
    var rb: [48]u8 = undefined;
    var sb: [24]u8 = undefined;
    appendMenuText(menu, MF_GRAYED, 0, conn_text);
    if (one_sided) {
        appendMenuText(menu, MF_GRAYED, 0, std.fmt.bufPrint(&lb, "Battery: {s}", .{common.fmtMenuSide(&sb, g_last.leftText(), g_unverified[0])}) catch "Battery: ?");
    } else {
        appendMenuText(menu, MF_GRAYED, 0, std.fmt.bufPrint(&lb, "Left: {s}", .{common.fmtMenuSide(&sb, g_last.leftText(), g_unverified[0])}) catch "Left: ?");
        appendMenuText(menu, MF_GRAYED, 0, std.fmt.bufPrint(&rb, "Right: {s}", .{common.fmtMenuSide(&sb, g_last.rightText(), g_unverified[1])}) catch "Right: ?");
    }
    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);

    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_REFRESH), menu_refresh);
    _ = AppendMenuW(menu, MF_STRING, @intCast(ID_TOGGLE), if (paused) menu_reconnect else menu_disconnect);
    var osd_flags: UINT = MF_STRING;
    if (g_state.osd_enabled.load(.acquire)) osd_flags |= MF_CHECKED;
    _ = AppendMenuW(menu, osd_flags, @intCast(ID_OSD_TOGGLE), menu_osd);
    if (g_update.isAvailable()) {
        appendMenuText(menu, MF_STRING, @intCast(ID_UPDATE), g_update.label());
    }
    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(menu, MF_GRAYED, 0, menu_version);
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
        ID_OSD_TOGGLE => {
            const now_on = !g_state.osd_enabled.load(.acquire);
            g_state.osd_enabled.store(now_on, .release);
            g_cfg.show_layer_overlay = now_on;
            if (g_config_path) |p| config.saveTo(g_io, g_gpa, p, g_cfg);
            // Turning it off: drop any queued change and hide a live OSD so
            // nothing lingers or pops after the user opts out.
            if (!now_on) {
                g_state.layer_change.store(-1, .release);
                if (g_osd_hwnd) |osd| {
                    _ = KillTimer(osd, ID_OSD_SHOW);
                    _ = KillTimer(osd, ID_OSD_HIDE);
                    _ = ShowWindow(osd, SW_HIDE);
                }
            }
        },
        ID_TOGGLE => {
            const now_paused = !paused;
            g_state.paused.store(now_paused, .release);
            // On reconnect, nudge the poll loop to re-scan immediately.
            if (!now_paused) g_state.refresh.store(true, .release);
            // Reflect the new state in the icon/tooltip right away.
            _ = PostMessageW(hwnd, WM_BATTERY_UPDATE, 0, 0);
        },
        ID_UPDATE => openReleasePage(),
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
    const unverified = g_state.unverified;
    const status = g_state.status;
    const model = g_state.model;
    const announce_pending = g_state.announce_connection and status == .connected and reading != null;
    g_state.mutex.unlock(g_io);
    g_unverified = unverified;
    const paused = g_state.paused.load(.acquire);
    const one_sided = if (model) |m| m.sides() < 2 else false;

    var icon_text: []const u8 = "--";
    var color: COLORREF = col_gray;
    var num_buf: [4]u8 = undefined;
    var battery_glyph: ?[]const u8 = null;

    // Refresh each side's last-known snapshot from a live reading, and run the
    // notification logic. Tooltip + icon below render from the snapshots, so
    // they always show a real per-side value even while a half is asleep.
    // Level and status are kept independently: a sleeping half often answers
    // one field (e.g. level=100) while the other comes back empty/unknown, and
    // clobbering a real "charging" with that "?" is exactly the stale-status bug.
    if (common.isLive(status, paused) and reading != null) {
        const r = reading.?;
        g_last.merge(r);

        // Drive notification LOGIC from the sticky-status snapshot, not the raw
        // reading: a charging side that momentarily reports an empty status
        // would otherwise look ".unknown" (i.e. "not charging") and fire a
        // false low-battery warning. The snapshot carries the last real status
        // per side.
        const snapshot: battery.Reading = .{ .left = g_last.left, .right = g_last.right };
        // Render the notification BODY from the fresh-status view (leftText/
        // rightText), exactly like the menu and tooltip: the sticky status
        // clings to an old "disconnected" long after the level reads fine
        // again, so the body must drop that stale suffix the moment a poll's
        // status comes back empty ("40%", not "40% (disconnected)").
        const display: battery.Reading = .{ .left = g_last.leftText(), .right = g_last.rightText() };
        // Gate the announcement on the raw reading (fresh levels present for
        // every battery-reporting side), but latch from the sticky snapshot —
        // matches the pre-refactor behavior and avoids announcing early off a
        // stale last-known value.
        const announce_ready = common.levelsKnown(model, r);
        const plan = common.planNotifications(&g_state.notified_low, announce_pending, announce_ready, snapshot, unverified);
        for (plan.events) |ev_opt| {
            if (ev_opt) |ev| showEvent(ev, model, display);
        }
        if (plan.consumed_announce) {
            g_state.mutex.lockUncancelable(g_io);
            g_state.announce_connection = false;
            g_state.mutex.unlock(g_io);
        }
    } else {
        g_state.notified_low = .{ false, false };
    }

    // Tooltip: last-known value for each battery-reporting side, in every
    // state, with a short header when the reading isn't live.
    {
        var lb: [40]u8 = undefined;
        var rb: [40]u8 = undefined;
        var tip_buf: [128]u8 = undefined;
        const header = common.tooltipHeader(status, paused);
        const tip = if (one_sided)
            std.fmt.bufPrint(&tip_buf, "{s}Battery: {s}", .{
                header,
                common.fmtKnownSide(&lb, g_last.leftText(), unverified[0]),
            }) catch "dygmate"
        else
            std.fmt.bufPrint(&tip_buf, "{s}Left: {s}\nRight: {s}", .{
                header,
                common.fmtKnownSide(&lb, g_last.leftText(), unverified[0]),
                common.fmtKnownSide(&rb, g_last.rightText(), unverified[1]),
            }) catch "dygmate";
        setUtf16(g_nid.szTip[0..], tip);
    }

    // Icon: the lower of the two last-known side levels. Dim to gray while
    // offline or paused; "--" only before either side has ever reported.
    const live = common.isLive(status, paused);
    const disp = g_last.display(common.hiddenSides(unverified));
    if (!paused and status == .missing) {
        icon_text = "?";
    } else if (live and g_last.allSidesDisconnected(model)) {
        // Both halves out of RF contact: their last-known levels are stale
        // cache, so show "?" (gray) rather than a misleading number.
        icon_text = "?";
    } else if (live and g_last.allSidesFull(model)) {
        // Both sides topped off → the full 🔋 glyph, regardless of status.
        color = toColorRef(common.iconColor(live, 100, disp.status));
        battery_glyph = common.battery_full_rgba;
    } else if (disp.level) |lvl| {
        color = toColorRef(common.iconColor(live, lvl, disp.status));
        if (live and disp.status == .charging) {
            // Charging (and not yet full): the battery-with-bolt glyph.
            battery_glyph = common.battery_charging_rgba;
        } else {
            icon_text = std.fmt.bufPrint(&num_buf, "{d}", .{lvl}) catch "?";
        }
    }

    const new_icon = makeTextIcon(icon_text, color, battery_glyph);
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

/// Open the published release URL in the default browser. ShellExecuteW is
/// non-blocking, so this is safe to call directly from the UI thread.
fn openReleasePage() void {
    const url = g_update.url();
    var wbuf: [512]u16 = undefined;
    const max = wbuf.len - 1;
    if (url.len > max) return;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0..max], url) catch return;
    wbuf[n] = 0;
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    _ = ShellExecuteW(null, verb, wbuf[0..n :0].ptr, null, null, SW_SHOWNORMAL);
}

/// Render one planner event as a tray balloon. connect_status shows per-side
/// detail; low_battery names the offending side (2-sided models). Warning
/// events use NIIF_WARNING.
fn showEvent(ev: common.NotifyEvent, model: ?device.Model, snapshot: battery.Reading) void {
    switch (ev.kind) {
        .connect_status => {
            var text_buf: [96]u8 = undefined;
            const text = common.fmtStatusBody(&text_buf, model, snapshot);
            const flags: DWORD = if (ev.warning) NIIF_WARNING else NIIF_INFO_ICON;
            showBalloon(common.notificationTitleStatus(model), text, flags);
        },
        .low_battery => {
            var tb: [64]u8 = undefined;
            const text = common.fmtLowBody(&tb, model, ev.side.?, ev.level.?);
            showBalloon(common.notificationTitleLow(model), text, NIIF_WARNING);
        },
    }
}

fn showBalloon(title: []const u8, text: []const u8, flags: DWORD) void {
    setUtf16(g_nid.szInfoTitle[0..], title);
    setUtf16(g_nid.szInfo[0..], text);
    g_nid.dwInfoFlags = flags;
    g_nid.uFlags = NIF_INFO;
    _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP; // restore for the next icon/tip update
}

fn drainLayerChanges() void {
    const layer_idx = g_state.layer_change.swap(-1, .acq_rel);
    if (layer_idx < 0) return;
    if (!g_state.osd_enabled.load(.acquire)) return;
    const hwnd = g_osd_hwnd orelse return;

    // Build the label now (captures the latest layer); the show itself may be
    // deferred by the configured delay.
    var label_buf: [16]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "Layer {d}", .{layer.displayNumber(@intCast(layer_idx))}) catch return;
    g_osd_text_len = std.unicode.utf8ToUtf16Le(g_osd_text[0 .. g_osd_text.len - 1], label) catch return;
    g_osd_text[g_osd_text_len] = 0;

    if (g_cfg.overlay_delay_ms == 0) {
        presentOsd(hwnd);
    } else {
        _ = KillTimer(hwnd, ID_OSD_SHOW);
        _ = SetTimer(hwnd, ID_OSD_SHOW, g_cfg.overlay_delay_ms, null);
    }
}

/// Position, show, and arm the auto-hide for the OSD using the label already
/// staged in `g_osd_text`. Called immediately or from the delayed show timer.
fn presentOsd(hwnd: HWND) void {
    var work = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const work_ptr: *anyopaque = @ptrCast(&work);
    if (SystemParametersInfoW(SPI_GETWORKAREA, 0, work_ptr, 0) == .FALSE) {
        work = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    }
    const x = work.left + @divTrunc((work.right - work.left) - osd_width, 2);
    const y = work.bottom - osd_height - osd_bottom_margin;

    _ = SetWindowPos(hwnd, HWND_TOPMOST, x, y, osd_width, osd_height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    _ = InvalidateRect(hwnd, null, .TRUE);
    _ = UpdateWindow(hwnd);
    _ = KillTimer(hwnd, ID_OSD_HIDE);
    _ = SetTimer(hwnd, ID_OSD_HIDE, g_cfg.overlay_duration_ms, null);
}

fn paintOsd(hwnd: HWND) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    var rect: RECT = undefined;
    if (GetClientRect(hwnd, &rect) == .FALSE) return;

    if (CreateSolidBrush(col_osd_transparent)) |brush| {
        _ = FillRect(hdc, &rect, brush);
        _ = DeleteObject(@ptrCast(brush));
    }

    if (CreateSolidBrush(col_osd_bg)) |brush| {
        const prev_brush = SelectObject(hdc, @ptrCast(brush));
        const pen = CreatePen(PS_SOLID, 2, col_osd_border);
        const prev_pen = if (pen) |p| SelectObject(hdc, @ptrCast(p)) else null;
        _ = RoundRect(
            hdc,
            1,
            1,
            osd_width - 1,
            osd_height - 1,
            osd_corner_diameter,
            osd_corner_diameter,
        );
        if (prev_pen) |pp| _ = SelectObject(hdc, pp);
        if (pen) |p| _ = DeleteObject(@ptrCast(p));
        if (prev_brush) |pb| _ = SelectObject(hdc, pb);
        _ = DeleteObject(@ptrCast(brush));
    }

    _ = SetBkColor(hdc, col_osd_bg);
    const font = CreateFontW(-22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, null);
    const prev_font = if (font) |f| SelectObject(hdc, @ptrCast(f)) else null;
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, col_text);
    var text_rect = RECT{ .left = 18, .top = 4, .right = osd_width - 18, .bottom = osd_height - 4 };
    _ = DrawTextW(hdc, &g_osd_text, @intCast(g_osd_text_len), &text_rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (font) |f| {
        if (prev_font) |pf| _ = SelectObject(hdc, pf);
        _ = DeleteObject(@ptrCast(f));
    }
}

/// Render `text` centered on a solid `color` 16x16 icon. Caller owns the
/// returned HICON (DestroyIcon). Returns null on any GDI failure.
fn makeTextIcon(text: []const u8, color: COLORREF, battery_glyph: ?[]const u8) ?HICON {
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

    if (battery_glyph) |glyph| {
        // Composite the shared battery glyph over the background pixel-by-pixel
        // (256 px) so it matches the Linux tray exactly; GDI text can't render
        // the 🔋 emoji. COLORREF is 0x00BBGGRR — unpack it back to an Rgb.
        const bg = common.Rgb{
            .r = @intCast(color & 0xFF),
            .g = @intCast((color >> 8) & 0xFF),
            .b = @intCast((color >> 16) & 0xFF),
        };
        const n: usize = @intCast(icon_size);
        var yy: usize = 0;
        while (yy < n) : (yy += 1) {
            var xx: usize = 0;
            while (xx < n) : (xx += 1) {
                const px = common.batteryPixel(glyph, n, xx, yy, bg);
                _ = SetPixelV(mdc, @intCast(xx), @intCast(yy), rgb(px.r, px.g, px.b));
            }
        }
    } else {
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
// Background polling thread: owns the serial connection. The loop itself lives
// in tray_common.zig; here we only supply the UI-wake callback (a window post).
// ---------------------------------------------------------------------------
fn pollLoop(ctx: *PollCtx) void {
    common.runPollLoop(PollCtx, ctx, ctx.io, ctx.gpa, ctx.state, wakeUi, true);
}

fn wakeUi(ctx: *PollCtx) void {
    _ = PostMessageW(ctx.hwnd, WM_BATTERY_UPDATE, 0, 0);
}

comptime {
    if (builtin.os.tag != .windows) @compileError("tray_windows.zig is Windows-only");
}

test {
    _ = @import("statusserver.zig");
}
