// copy_path.cpp
// 无窗口剪贴板工具：将传入的文件/文件夹路径以文本形式复制到系统剪贴板。
// 供资源管理器右键菜单调用，由同目录 CopyFilePath-Setup.ps1 编译部署。
//
// 两种输出模式（由可选首参数指定，默认不带引号）：
//   copy_path.exe "D:\a b.txt"       => D:\a b.txt          （不带引号）
//   copy_path.exe -q "D:\a b.txt"    => "D:\a b.txt"        （带引号，-q / --quote / /q 均可）
//
// 对应右键菜单注册（HKCU\Software\Classes，三处均注册）：
//   「复制文件路径(带引号)」verb=CopyFilePath       命令: ...\copy_path.exe -q "%1"（背景处为 "%V"）
//   「复制文件路径」        verb=CopyFilePathPlain   命令: ...\copy_path.exe "%1"（背景处为 "%V"）
//
// 多选支持：Explorer 多选时会对每个选中项各启动一次本程序（每次只传一个路径）。
// 聚合机制：
//   - 写入文本的同时，附带一个自定义剪贴板格式 CopyFilePath_SessionStamp（时间戳）
//   - 新实例读取该时间戳：若距上次写入不足 2 秒（滑动窗口）则进入追加模式，
//     读取现有文本 + 换行 + 自己的路径后整体重写；否则重置模式，只写自己的路径
//   - 命名 Mutex 把并发实例的 读-改-写 整体串行化，避免竞态
//   - 用户一旦复制了别的内容，时间戳格式随之消失，自动回到重置模式
// 多个选中项最终合并为多行文本，每行一个完整路径。
//
// 编译: g++ -O2 -mwindows -municode -static -o copy_path.exe copy_path.cpp
//       （CopyFilePath-Setup.ps1 添加菜单时会自动完成编译并部署）

#include <windows.h>
#include <string>

static const wchar_t* kStampFormatName = L"CopyFilePath_SessionStamp";
static const wchar_t* kMutexName       = L"Local\\CopyFilePath_Mutex";
static const ULONGLONG kWindowMs = 2000;   // 多实例聚合的滑动时间窗口

// 忽略大小写比较
static bool EqNoCase(const std::wstring& s, const wchar_t* t) {
    size_t i = 0;
    for (; i < s.size() && t[i]; ++i) {
        if (towlower(s[i]) != towlower(t[i])) return false;
    }
    return i == s.size() && t[i] == 0;
}

static std::wstring TrimWs(const std::wstring& s) {
    size_t b = s.find_first_not_of(L" \t\r\n");
    if (b == std::wstring::npos) return std::wstring();
    size_t e = s.find_last_not_of(L" \t\r\n");
    return s.substr(b, e - b + 1);
}

// 解析命令行：可选首参数 -q/--quote//q（带引号模式），其余去空白、去外层引号
static std::wstring ParsePath(PWSTR lpCmdLine, bool& quoteMode) {
    std::wstring path = TrimWs(std::wstring(lpCmdLine ? lpCmdLine : L""));
    if (path.empty()) return std::wstring();

    // 可选模式开关：必须是第一个独立 token
    if (path[0] == L'-' || path[0] == L'/') {
        size_t sp = path.find_first_of(L" \t");
        std::wstring tok = (sp == std::wstring::npos) ? path : path.substr(0, sp);
        if (EqNoCase(tok, L"-q") || EqNoCase(tok, L"--quote") || EqNoCase(tok, L"/q")) {
            quoteMode = true;
            if (sp == std::wstring::npos) return std::wstring();
            path = TrimWs(path.substr(sp + 1));
            if (path.empty()) return std::wstring();
        }
    }

    if (path.size() >= 2 && path.front() == L'"' && path.back() == L'"') {
        path = path.substr(1, path.size() - 2);
    }
    if (quoteMode && !path.empty()) {
        path = L"\"" + path + L"\"";
    }
    return path;
}

// 打开剪贴板，失败重试（可能被其他进程短暂占用）
static bool OpenClipboardRetry() {
    for (int i = 0; i < 10; ++i) {
        if (OpenClipboard(nullptr)) return true;
        Sleep(30);
    }
    return false;
}

// 读取当前剪贴板里的会话时间戳；不存在或已超窗口返回 0（重置模式）
static ULONGLONG ReadSessionStamp(UINT stampFmt) {
    HANDLE hData = GetClipboardData(stampFmt);
    if (!hData) return 0;
    ULONGLONG stamp = 0;
    ULONGLONG* p = (ULONGLONG*)GlobalLock(hData);
    if (p) {
        stamp = *p;
        GlobalUnlock(hData);
    }
    return stamp;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR lpCmdLine, int) {
    bool quoteMode = false;
    std::wstring path = ParsePath(lpCmdLine, quoteMode);
    if (path.empty()) return 1;

    UINT stampFmt = RegisterClipboardFormatW(kStampFormatName);
    if (!stampFmt) return 4;

    // 命名 Mutex：串行化并发实例的整个 读-改-写 过程
    HANDLE hMutex = CreateMutexW(nullptr, FALSE, kMutexName);
    if (!hMutex) return 5;
    DWORD waitResult = WaitForSingleObject(hMutex, 3000);
    if (waitResult != WAIT_OBJECT_0 && waitResult != WAIT_ABANDONED) {
        CloseHandle(hMutex);
        return 5;
    }

    if (!OpenClipboardRetry()) {
        ReleaseMutex(hMutex);
        CloseHandle(hMutex);
        return 2;
    }

    // 判断追加/重置：时间戳存在且距现在不足窗口 => 同一会话
    ULONGLONG stamp = ReadSessionStamp(stampFmt);
    bool append = (stamp != 0 && (GetTickCount64() - stamp) < kWindowMs);

    // 组装最终文本
    std::wstring text;
    if (append) {
        HANDLE hData = GetClipboardData(CF_UNICODETEXT);
        if (hData) {
            const wchar_t* prev = (const wchar_t*)GlobalLock(hData);
            if (prev) {
                text = prev;
                GlobalUnlock(hData);
            }
        }
    }
    if (!text.empty()) text += L"\r\n";
    text += path;

    // 整体重写：文本 + 会话时间戳
    EmptyClipboard();

    size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (hMem) {
        void* buf = GlobalLock(hMem);
        if (buf) {
            memcpy(buf, text.c_str(), bytes);
            GlobalUnlock(hMem);
            if (!SetClipboardData(CF_UNICODETEXT, hMem)) GlobalFree(hMem);
        } else {
            GlobalFree(hMem);
        }
    }

    HGLOBAL hStamp = GlobalAlloc(GMEM_MOVEABLE, sizeof(ULONGLONG));
    if (hStamp) {
        ULONGLONG* p = (ULONGLONG*)GlobalLock(hStamp);
        if (p) {
            *p = GetTickCount64();
            GlobalUnlock(hStamp);
            if (!SetClipboardData(stampFmt, hStamp)) GlobalFree(hStamp);
        } else {
            GlobalFree(hStamp);
        }
    }

    CloseClipboard();
    ReleaseMutex(hMutex);
    CloseHandle(hMutex);
    return 0;
}
