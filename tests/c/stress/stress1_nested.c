// Stress test 1: Deeply nested function calls + stdlib call.
// Cursor on `complex` (0-based (12, 4)).
// Expect: external_calls contains `helper1`, `helper2`, `helper3` (resolved)
//         and `printf` (likely marked resolved but body range nil, since
//         stdio.h is a system header).
#include <stdio.h>

int helper1(int x) { return x + 1; }
int helper2(int x) { return x * 2; }
int helper3(int x) { return x - 3; }

int outer(int x) {
    int a = helper1(x);
    int b = helper2(a);
    int c = helper3(b);
    return c;
}

int medium(int x) {
    return outer(x) + helper1(x);
}

int complex(int x) {
    int v = medium(x);
    printf("result: %d\n", v);
    return v;
}
