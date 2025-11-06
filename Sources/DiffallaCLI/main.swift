if #available(macOS 14.0, *) {
    DiffallaTool.main()
} else {
    fatalError("This tool requires macOS 14.0 or later")
}
