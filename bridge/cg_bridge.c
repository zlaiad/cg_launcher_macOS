#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <fcntl.h>
#include <io.h>

/* Receives a length-delimited request on stdin. Secrets never appear in argv. */
static int read_exact(void *p, size_t n) { return fread(p, 1, n, stdin) == n; }
static uint32_t read_u32(void) {
    unsigned char b[4];
    if (!read_exact(b, 4)) exit(20);
    return b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static char *read_string(uint32_t maximum) {
    uint32_t n = read_u32();
    if (n > maximum) exit(21);
    char *s = calloc((size_t)n + 1, 1);
    if (!s || !read_exact(s, n) || memchr(s, 0, n)) exit(22);
    return s;
}
static wchar_t *wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) exit(23);
    wchar_t *w = calloc((size_t)n, sizeof(wchar_t));
    if (!w || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n)) exit(23);
    return w;
}
/* The game's legacy unpacker reopens its image through ANSI file APIs.
 * Wine can use ACP 1252 even though the installed path contains Chinese.
 * Preserve a representable image and working-directory path for that code. */
static void check_legacy_path(const wchar_t *path) {
    BOOL lossy = FALSE;
    int n = WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, path, -1, NULL, 0, NULL, &lossy);
    if (n <= 0 || lossy) exit(39);
    char *ansi = calloc((size_t)n, 1);
    if (!ansi || !WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, path, -1, ansi, n, NULL, &lossy) ||
        lossy || GetFileAttributesA(ansi) == INVALID_FILE_ATTRIBUTES) exit(39);
    free(ansi);
}
/* Windows command-line quoting, including backslashes before quotes/end. */
static void append_quoted(wchar_t *dst, size_t *used, const wchar_t *s) {
    size_t slashes = 0;
    #define PUT(c) do { if (*used >= 32765) exit(24); dst[(*used)++] = (c); } while (0)
    if (*used) PUT(L' ');
    PUT(L'"');
    for (;;) {
        wchar_t c = *s++;
        if (c == L'\\') { slashes++; continue; }
        if (c == L'"' || c == 0) {
            for (size_t j = 0; j < slashes * 2; j++) PUT(L'\\');
            if (c == L'"') PUT(L'\\');
        } else for (size_t j = 0; j < slashes; j++) PUT(L'\\');
        slashes = 0;
        if (!c) break;
        PUT(c);
    }
    PUT(L'"');
    dst[*used] = 0;
    #undef PUT
}
static void binary_test_payload(char *buffer) {
    const char *prefix = "gid:synthetic glt:";
    size_t n = strlen(prefix);
    memcpy(buffer, prefix, n);
    for (unsigned int i = 0; i < 32; i++) buffer[n + i] = (char)(0x80 + i);
    memcpy(buffer + n + 32, ":1 ", 4);
}
static int self_test(const char *payload, int binary) {
    char name[80];
    snprintf(name, sizeof(name), "CGLauncherSelfTest_%lu", GetCurrentProcessId());
    HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 256, name);
    if (!h) return 30;
    char *v = MapViewOfFile(h, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 256);
    if (!v) { CloseHandle(h); return 31; }
    memcpy(v, payload, strlen(payload) + 1);
    HANDLE h2 = OpenFileMappingA(FILE_MAP_READ, FALSE, name);
    char *v2 = h2 ? MapViewOfFile(h2, FILE_MAP_READ, 0, 0, 256) : NULL;
    int ok = v2 && memcmp(v2, payload, strlen(payload) + 1) == 0;
    if (v2) UnmapViewOfFile(v2);
    if (h2) CloseHandle(h2);
    wchar_t self[MAX_PATH], command[32768] = {0}; size_t used = 0;
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) ok = 0;
    if (ok) {
        append_quoted(command, &used, self);
        append_quoted(command, &used, binary ? L"--test-binary-child" : L"--test-child");
        wchar_t *name_w = wide(name); append_quoted(command, &used, name_w); free(name_w);
        STARTUPINFOW startup = {0}; startup.cb = sizeof(startup);
        PROCESS_INFORMATION child = {0};
        ok = CreateProcessW(self, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child);
        if (ok) {
            CloseHandle(child.hThread);
            DWORD code = 1;
            if (WaitForSingleObject(child.hProcess, 10000) == WAIT_OBJECT_0) GetExitCodeProcess(child.hProcess, &code);
            else TerminateProcess(child.hProcess, 1);
            CloseHandle(child.hProcess); ok = code == 0;
        }
    }
    SecureZeroMemory(v, 256); UnmapViewOfFile(v); CloseHandle(h);
    puts(ok ? "BRIDGE_SELF_TEST_OK" : "BRIDGE_SELF_TEST_FAILED");
    return ok ? 0 : 32;
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--locale-check") == 0) {
        printf("BRIDGE_LOCALE acp=%u\n", GetACP());
        return GetACP() == 936 ? 0 : 39;
    }
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return self_test("synthetic-test-only", 0);
    if (argc == 3 && (strcmp(argv[1], "--test-child") == 0 || strcmp(argv[1], "--test-binary-child") == 0)) {
        if (strncmp(argv[2], "CGLauncherSelfTest_", 19)) return 36;
        HANDLE h = OpenFileMappingA(FILE_MAP_READ, FALSE, argv[2]);
        const char *v = h ? MapViewOfFile(h, FILE_MAP_READ, 0, 0, 256) : NULL;
        char expected[256] = "synthetic-test-only";
        if (strcmp(argv[1], "--test-binary-child") == 0) binary_test_payload(expected);
        int ok = v && memcmp(v, expected, strlen(expected) + 1) == 0;
        char image[MAX_PATH];
        ok = ok && GetModuleFileNameA(NULL, image, MAX_PATH) && GetFileAttributesA(image) != INVALID_FILE_ATTRIBUTES;
        if (v) UnmapViewOfFile(v);
        if (h) CloseHandle(h);
        return ok ? 0 : 37;
    }
    _setmode(_fileno(stdin), _O_BINARY);
    char magic[4];
    if (!read_exact(magic, 4) || memcmp(magic, "CGM1", 4)) return 20;
    char *auth = read_string(255);
    if (strncmp(auth, "gid:", 4) || !strstr(auth, " glt:")) return 25;
    char *exe = read_string(4096), *cwd = read_string(4096);
    wchar_t *exe_w = wide(exe), *cwd_w = wide(cwd);
    int binary_validation = argc == 2 && strcmp(argv[1], "--validate-binary-input") == 0;
    int validation = binary_validation || (argc == 2 && strcmp(argv[1], "--validate-input") == 0);
    if (!validation) { check_legacy_path(exe_w); check_legacy_path(cwd_w); }
    wchar_t command[32768] = {0}; size_t used = 0;
    append_quoted(command, &used, exe_w);
    uint32_t count = read_u32();
    if (count > 256) return 21;
    for (uint32_t i = 0; i < count; i++) {
        char *arg = read_string(1024); wchar_t *arg_w = wide(arg);
        append_quoted(command, &used, arg_w); free(arg_w); free(arg);
    }
    if (validation) {
        char expected[256] = "gid:synthetic glt:synthetic:1 ";
        if (binary_validation) binary_test_payload(expected);
        int ok = strlen(auth) == strlen(expected) && memcmp(auth, expected, strlen(expected)) == 0;
        if (ok && binary_validation) ok = self_test(auth, 1) == 0;
        SecureZeroMemory(auth, strlen(auth)); free(auth);
        free(exe_w); free(cwd_w); free(exe); free(cwd);
        if (ok) puts("BRIDGE_STDIN_VALIDATED");
        return ok ? 0 : 38;
    }
    HANDLE mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 256, "CGSharedMem");
    if (!mapping) return 33;
    char *view = MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 256);
    if (!view) { CloseHandle(mapping); return 34; }
    memcpy(view, auth, strlen(auth) + 1);
    SecureZeroMemory(auth, strlen(auth)); free(auth);
    STARTUPINFOW startup = {0}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION child = {0};
    BOOL ok = CreateProcessW(exe_w, command, NULL, NULL, FALSE, 0, NULL, cwd_w, &startup, &child);
    DWORD child_exit = 0;
    free(exe_w); free(cwd_w); free(exe); free(cwd);
    if (ok) {
        printf("GAME_STARTED %lu\n", child.dwProcessId); fflush(stdout);
        CloseHandle(child.hThread);
        WaitForSingleObject(child.hProcess, INFINITE);
        GetExitCodeProcess(child.hProcess, &child_exit);
        CloseHandle(child.hProcess);
    } else { printf("GAME_START_FAILED %lu\n", GetLastError()); fflush(stdout); }
    /* Do not clear a shared mapping: another official login may have updated it. */
    UnmapViewOfFile(view); CloseHandle(mapping);
    return ok ? (child_exit == 0 ? 0 : 46) : 35;
}
