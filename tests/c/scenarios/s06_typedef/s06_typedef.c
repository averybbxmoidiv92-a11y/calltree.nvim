typedef int (*Op)(int, int);
int apply(Op op, int a, int b) { return op(a, b); }
