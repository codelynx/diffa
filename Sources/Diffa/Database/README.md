# SQLite Database Wrapper

A lightweight, type-safe SQLite wrapper for Swift with zero external dependencies. Works on macOS, iOS, and Linux.

## Features

- ✅ **Type-safe API** - `SQLiteValue` enum prevents type errors and SQL injection
- ✅ **Cross-platform** - macOS, iOS, Linux support
- ✅ **Zero dependencies** - Uses system libsqlite3
- ✅ **RAII pattern** - Automatic resource cleanup
- ✅ **Transaction support** - ACID-compliant transactions
- ✅ **Prepared statements** - Reusable statements for performance
- ✅ **Named parameters** - Support for both `?` and `:name` placeholders

## Basic Usage

### Opening a Database

```swift
import Diffa

// Create or open database
let db = try SQLiteDatabase(path: "/path/to/database.sqlite")
```

### Creating Tables

```swift
try db.execute("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        age INTEGER,
        email TEXT UNIQUE
    )
""")
```

### Inserting Data

**Positional parameters:**
```swift
try db.run(
    "INSERT INTO users (name, age, email) VALUES (?, ?, ?)",
    [.text("Alice"), .integer(30), .text("alice@example.com")]
)

print("Inserted row ID: \(db.lastInsertRowID)")
```

**Named parameters:**
```swift
try db.run(
    "INSERT INTO users (name, age, email) VALUES (:name, :age, :email)",
    [
        "name": .text("Bob"),
        "age": .integer(25),
        "email": .text("bob@example.com")
    ]
)
```

### Querying Data

```swift
let rows = try db.query("SELECT * FROM users WHERE age > ?", [.integer(20)])

for row in rows {
    let name = try row.string(at: 1)  // By index
    let age = try row.int(at: 2)
    print("\(name ?? "Unknown") is \(age) years old")
}
```

**Query with column names:**
```swift
let rows = try db.query("SELECT name, age FROM users")

for row in rows {
    let name = try row.string(for: "name")  // By name
    let age = try row.int64(for: "age")
    print("\(name ?? "Unknown"): \(age)")
}
```

### Updating and Deleting

```swift
// Update
try db.run(
    "UPDATE users SET age = ? WHERE name = ?",
    [.integer(31), .text("Alice")]
)
print("Updated \(db.changes) rows")

// Delete
try db.run("DELETE FROM users WHERE age < ?", [.integer(18)])
```

## Data Types

The `SQLiteValue` enum provides type-safe value handling:

```swift
public enum SQLiteValue {
    case integer(Int64)     // SQLite INTEGER
    case real(Double)       // SQLite REAL
    case text(String)       // SQLite TEXT
    case blob(Data)         // SQLite BLOB
    case null               // SQLite NULL
}
```

### Convenience Initializers

```swift
SQLiteValue(42)                    // .integer(42)
SQLiteValue(true)                  // .integer(1)
SQLiteValue("text")                // .text("text")
SQLiteValue(someOptionalString)    // .text or .null
```

### Type Accessors

```swift
let row = rows[0]

// Type-safe accessors
let id = try row.int64(at: 0)      // Int64
let age = try row.int(at: 1)       // Int
let name = try row.string(at: 2)   // String?
let active = try row.bool(at: 3)   // Bool (0 = false, 1 = true)
let price = try row.double(at: 4)  // Double
let data = try row.data(at: 5)     // Data?
```

## Transactions

```swift
try db.transaction {
    try db.run("INSERT INTO accounts (balance) VALUES (?)", [.integer(100)])
    try db.run("INSERT INTO accounts (balance) VALUES (?)", [.integer(200)])
    // Both inserts committed together
}

// On error, transaction rolls back automatically
do {
    try db.transaction {
        try db.run("INSERT INTO accounts (balance) VALUES (?)", [.integer(100)])
        throw MyError.someError
    }
} catch {
    // Transaction was rolled back
}
```

## Prepared Statements

Reuse prepared statements for better performance:

```swift
let stmt = try db.prepare("INSERT INTO users (name, age) VALUES (?, ?)")

// Insert multiple rows
for user in users {
    try stmt.bind([.text(user.name), .integer(user.age)])
    try stmt.execute()
    stmt.reset()  // Reset for next use
}
```

## BLOB Support

```swift
// Insert binary data
let imageData = UIImage(named: "photo")?.pngData()
try db.run(
    "INSERT INTO images (name, data) VALUES (?, ?)",
    [.text("photo.png"), .blob(imageData ?? Data())]
)

// Retrieve binary data
let rows = try db.query("SELECT data FROM images WHERE name = ?", [.text("photo.png")])
if let data = try rows.first?.data(at: 0) {
    let image = UIImage(data: data)
}
```

## NULL Handling

```swift
// Insert NULL
try db.run("INSERT INTO users (name, email) VALUES (?, ?)", [.text("John"), .null])

// Check for NULL
let rows = try db.query("SELECT email FROM users")
if case .null = try rows[0].value(at: 0) {
    print("Email is NULL")
}

// String accessor returns nil for NULL
let email = try rows[0].string(at: 0)  // Returns nil if NULL
```

## Foreign Keys

Foreign keys are enabled by default:

```swift
try db.execute("""
    CREATE TABLE posts (
        id INTEGER PRIMARY KEY,
        user_id INTEGER NOT NULL,
        content TEXT,
        FOREIGN KEY (user_id) REFERENCES users(id)
    )
""")

// This will fail if user_id doesn't exist
try db.run("INSERT INTO posts (user_id, content) VALUES (?, ?)", [.integer(999), .text("Hello")])
// Throws: foreign key constraint failed
```

## Error Handling

All database operations can throw `SQLiteError`:

```swift
do {
    try db.execute("INVALID SQL")
} catch SQLiteError.executeFailed(let message, let sql) {
    print("Error: \(message)")
    print("SQL: \(sql)")
} catch {
    print("Other error: \(error)")
}
```

### Error Types

```swift
public enum SQLiteError: Error {
    case openFailed(message: String)
    case executeFailed(message: String, sql: String)
    case prepareFailed(message: String, sql: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case invalidColumnIndex(index: Int)
    case invalidColumnType(column: String, expected: String)
    case closeFailed(message: String)
}
```

## Utility Methods

```swift
// Check if table exists
if try db.tableExists("users") {
    print("Table exists")
}

// Get SQLite version
print("SQLite version: \(SQLiteDatabase.version)")
print("Version number: \(SQLiteDatabase.versionNumber)")

// Get changes count
try db.run("UPDATE users SET age = age + 1")
print("Updated \(db.changes) rows")
```

## Performance Tips

### 1. Use Transactions for Bulk Inserts

```swift
// Slow: Each insert is its own transaction
for i in 0..<10000 {
    try db.run("INSERT INTO test VALUES (?)", [.integer(Int64(i))])
}

// Fast: Single transaction
try db.transaction {
    for i in 0..<10000 {
        try db.run("INSERT INTO test VALUES (?)", [.integer(Int64(i))])
    }
}
```

### 2. Reuse Prepared Statements

```swift
// Prepare once, execute many times
let stmt = try db.prepare("INSERT INTO test VALUES (?)")
try db.transaction {
    for i in 0..<10000 {
        try stmt.bind([.integer(Int64(i))])
        try stmt.execute()
        stmt.reset()
    }
}
```

### 3. Use Indexes

```swift
try db.execute("CREATE INDEX idx_users_email ON users(email)")
```

### 4. Enable WAL Mode (Enabled by Default)

Write-Ahead Logging improves concurrency:
```swift
// Already enabled by default in SQLiteDatabase init
try db.execute("PRAGMA journal_mode = WAL")
```

## Thread Safety

**Important:** A single `SQLiteDatabase` instance is not thread-safe. Each thread should have its own connection.

```swift
// Thread 1
let db1 = try SQLiteDatabase(path: "db.sqlite")

// Thread 2
let db2 = try SQLiteDatabase(path: "db.sqlite")

// Both can safely access the same database file
```

## Linux Support

On Linux, ensure SQLite development headers are installed:

```bash
# Ubuntu/Debian
sudo apt-get install libsqlite3-dev

# Fedora/RHEL
sudo dnf install sqlite-devel
```

The Package.swift already includes the correct linker settings for all platforms.

## Example: Complete CRUD

```swift
import Diffa

// Setup
let db = try SQLiteDatabase(path: "app.sqlite")

try db.execute("""
    CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        completed INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
    )
""")

// Create
func createTodo(title: String) throws -> Int64 {
    try db.run(
        "INSERT INTO todos (title, created_at) VALUES (?, ?)",
        [.text(title), .text(ISO8601DateFormatter().string(from: Date()))]
    )
    return db.lastInsertRowID
}

// Read
func getTodos() throws -> [(id: Int64, title: String, completed: Bool)] {
    let rows = try db.query("SELECT id, title, completed FROM todos ORDER BY id")
    return try rows.map { row in
        (
            id: try row.int64(at: 0),
            title: try row.string(at: 1) ?? "",
            completed: try row.bool(at: 2)
        )
    }
}

// Update
func updateTodo(id: Int64, completed: Bool) throws {
    try db.run(
        "UPDATE todos SET completed = ? WHERE id = ?",
        [SQLiteValue(completed), .integer(id)]
    )
}

// Delete
func deleteTodo(id: Int64) throws {
    try db.run("DELETE FROM todos WHERE id = ?", [.integer(id)])
}

// Usage
let id = try createTodo(title: "Learn SQLite")
try updateTodo(id: id, completed: true)
let todos = try getTodos()
print("Todos: \(todos)")
try deleteTodo(id: id)
```

## Testing

Run tests with:
```bash
swift test
```

See `Tests/DiffaTests/SQLiteDatabaseTests.swift` for comprehensive test coverage.
