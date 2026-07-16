void target() {}
void dispatcher(void (*fp)()) {
    fp();
}
