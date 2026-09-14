#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <io.h>

/* Raw transport only. Swift performs the protocol and encryption. No files/logs. */
static SOCKET connection = INVALID_SOCKET;
static int output(const void *bytes, int count) {
    const char *p = bytes;
    while (count > 0) {
        int n = _write(_fileno(stdout), p, count);
        if (n <= 0) return 0;
        p += n; count -= n;
    }
    return 1;
}
static DWORD WINAPI upload(LPVOID unused) {
    (void)unused;
    char buffer[4096]; int n;
    while ((n = _read(_fileno(stdin), buffer, sizeof(buffer))) > 0) {
        int offset = 0;
        while (offset < n) {
            int sent = send(connection, buffer + offset, n - offset, 0);
            if (sent <= 0) { shutdown(connection, SD_BOTH); return 1; }
            offset += sent;
        }
    }
    shutdown(connection, SD_BOTH);
    return 0;
}
int main(int argc, char **argv) {
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
    /* Restrict this helper to the installed official billing services. */
    if (argc != 3 || strcmp(argv[2], "9030") ||
        (strcmp(argv[1], "221.122.108.12") && strcmp(argv[1], "221.122.119.158"))) return 40;
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 41;
    connection = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (connection == INVALID_SOCKET) return 42;
    struct sockaddr_in address = {0}; address.sin_family = AF_INET;
    address.sin_port = htons(9030); address.sin_addr.s_addr = inet_addr(argv[1]);
    u_long nonblocking = 1; ioctlsocket(connection, FIONBIO, &nonblocking);
    int result = connect(connection, (struct sockaddr *)&address, sizeof(address));
    if (result && WSAGetLastError() == WSAEWOULDBLOCK) {
        fd_set writable; FD_ZERO(&writable); FD_SET(connection, &writable);
        struct timeval interval = {10, 0};
        result = select(0, NULL, &writable, NULL, &interval);
        int error = 1, size = sizeof(error);
        if (result > 0 && getsockopt(connection, SOL_SOCKET, SO_ERROR, (char *)&error, &size) == 0 && error == 0) result = 0;
        else result = 1;
    }
    if (result) { closesocket(connection); WSACleanup(); return 43; }
    nonblocking = 0; ioctlsocket(connection, FIONBIO, &nonblocking);
    DWORD timeout = 30000;
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof(timeout));
    if (!output("CGN1", 4)) return 44;
    HANDLE thread = CreateThread(NULL, 0, upload, NULL, 0, NULL);
    if (!thread) return 45;
    char buffer[4096]; int n;
    while ((n = recv(connection, buffer, sizeof(buffer), 0)) > 0) {
        if (!output(buffer, n)) break;
    }
    shutdown(connection, SD_BOTH); closesocket(connection);
    CloseHandle(thread); WSACleanup();
    return 0;
}
