/// Per-view values for the shaders' fixed-size per-view arrays: the second entry repeats the first for one view.
func viewPair<T>(_ values: [T]) -> (T, T) {
    (values[0], values.count > 1 ? values[1] : values[0])
}
