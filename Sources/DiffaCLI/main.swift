if #available(macOS 13.0, *) {
    DiffaTool.main()
} else {
    fatalError("This tool requires macOS 13.0 or later")
}
