if #available(macOS 13.0, *) {
    DiffallaTool.main()
} else {
    fatalError("This tool requires macOS 13.0 or later")
}
