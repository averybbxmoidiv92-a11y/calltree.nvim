struct Math { int (*add)(int, int); };
int real_add(int a, int b) { return a + b; }
void use() {
    struct Math m = { .add = real_add };
    m.add(2, 3);
}
