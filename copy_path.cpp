// copy_path.cpp
// 无窗口剪贴板工具：接收一个文件/文件夹路径作为命令行参数，
// 将其文本路径复制到系统剪贴板。供资源管理器右键菜单调用。
// 编译: g++ -O2 -mwindows -municode -static -o copy_path.exe copy_path.cpp

#include <windows.h>
#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR lpCmdLine, int) {
    std::wstring path(lpCmdLine);

    // 去掉首尾空白
    size_t s = path.find_first_not_of(L" \t\r\n");
    if (s == std::wstring::npos) return 1;
    path = path.substr(s);
    size_t e = path.find_last_not_of(L" \t\r\n");
    path = path.substr(0, e + 1);

    // 去掉外层双引号（Explorer 传 %1/%V 时会加引号）
    if (path.size() >= 2 && path.front() == L'"' && path.back() == L'"') {
        path = path.substr(1, path.size() - 2);
    }
    if (path.empty()) return 1;

    // 剪贴板可能被占用，重试几次
    BOOL opened = FALSE;
    for (int i = 0; i < 10; ++i) {
        if (OpenClipboard(nullptr)) { opened = TRUE; break; }
        Sleep(30);
    }
    if (!opened) return 2;

    EmptyClipboard();

    size_t bytes = (path.size() + 1) * sizeof(wchar_t);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!hMem) { CloseClipboard(); return 3; }

    void* buf = GlobalLock(hMem);
    if (buf) {
        memcpy(buf, path.c_str(), bytes);
        GlobalUnlock(hMem);
        if (!SetClipboardData(CF_UNICODETEXT, hMem)) {
            GlobalFree(hMem);
        }
    } else {
        GlobalFree(hMem);
    }

    CloseClipboard();
    return 0;
}
