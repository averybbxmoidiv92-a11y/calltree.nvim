#define FEATURE
int real_add(int a, int b) { return a + b; }
void calc(int x) {
#ifdef FEATURE
    real_add(x, 1);
#else
    dummy(x);
#endif
}
