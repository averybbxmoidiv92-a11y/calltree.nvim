// Stress test 3: Function with many local variables, if/else branches,
// loops, and a mix of calls. Cursor on `process` (0-based (10, 4)).
// This tests the plugin's ability to handle realistic C code with control
// flow and multiple call sites in different branches.
#include <stdio.h>

int validate(int x) {
    if (x < 0) return 0;
    return 1;
}

int transform(int x) {
    int result = 0;
    for (int i = 0; i < x; i++) {
        result += i;
    }
    return result;
}

int format(int x) {
    printf("value=%d\n", x);
    return x;
}

int process(int input) {
    if (!validate(input)) {
        return -1;
    }
    int t = transform(input);
    if (t > 100) {
        format(t);
        return t;
    } else {
        format(0);
        return 0;
    }
}
