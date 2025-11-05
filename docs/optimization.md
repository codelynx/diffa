# Optimization (Objective 5)

## Goal

Optimize efficient synchronization to minimize file operations, using moves instead of copy+delete where possible, and reducing overall I/O.

## Use Cases

### Large-scale Synchronization
- Syncing large directory trees with thousands of files
- Minimizing time and resources required
- Reducing wear on storage devices

### Bandwidth-constrained Environments
- Remote synchronization over slow connections
- Minimize data transfer
- Maximize use of existing files

### Frequent Synchronization
- Regularly syncing folders with small changes
- Avoid re-copying unchanged files
- Quick incremental updates

## Optimization Strategies

### 1. Move Detection

Detect when a file was moved/renamed rather than deleted and re-added.

**Benefits:**
- Avoid copying large files
- Preserve file system metadata
- Faster operations
- Reduced I/O

**Algorithm:**

```
For each removed file R:
	For each added file A:
		If R.sha256 == A.sha256:
			Mark as MOVE operation (R.path → A.path)
			Remove from added list
			Remove from removed list
```

**Optimization:**
- Build hash map for O(1) lookup
- Only compare files with same size first
- Skip move detection for small files (copy may be faster)

### 2. Copy Avoidance

Avoid copying files that already exist at destination.

**Scenarios:**
- File already exists with same content (check hash)
- File was moved on source but already exists at new location
- File exists in multiple locations (hardlink candidate)

**Algorithm:**

```
For each file to copy:
	If destination already has file with same hash:
		If at correct location:
			Skip copy
		Else:
			Move existing file instead of copy
```

### 3. Incremental Hashing

Avoid re-computing hashes for unchanged files.

**Strategy:**
- Cache file hashes with modification timestamp
- If file timestamp unchanged, use cached hash
- Invalidate cache on timestamp change

**Implementation:**

```swift
struct HashCache {
	let filePath: String
	let modificationDate: Date
	let size: Int64
	let sha256: String
}
```

**Cache storage:**
- In-memory cache for session
- Persistent cache for repeated operations (optional)
- Clear cache on file modification

### 4. Smart File Comparison

Choose comparison method based on file characteristics.

**Size-first comparison:**
```
If file sizes differ:
	Files are different (no need to hash)
Else:
	Compute and compare hashes
```

**Quick-check for small files:**
- For small files (< 1MB), hash computation is cheap
- For large files (> 100MB), size check saves significant time

**Modification time optimization:**
```
If modification timestamps same AND size same:
	Assume files are identical (risky but fast)
	Optional: Verify with hash for critical operations
```

### 5. Parallel Processing

Process multiple files concurrently.

**Strategies:**
- Hash computation in parallel (CPU-bound)
- File copying in parallel (I/O-bound)
- Balance parallelism to avoid overwhelming system

**Considerations:**
- Limit concurrent operations based on CPU/disk
- Prioritize based on file size (large files first)
- Avoid contention on same disk

### 6. Block-level Delta Synchronization

For modified files, only transfer changed blocks (future enhancement).

**Benefits:**
- Dramatically reduce data transfer for large files with small changes
- Similar to rsync algorithm

**Algorithm:**
- Divide files into fixed-size blocks
- Compute checksums for each block
- Identify which blocks changed
- Only transfer changed blocks

**Complexity:**
- More complex implementation
- Useful for very large files
- May not be worth it for small files

### 7. Deduplication

Identify and handle duplicate files efficiently.

**Detection:**
- Files with same hash are duplicates
- Can be represented by same underlying data

**Strategies:**
- Hard links (same inode, different paths)
- Reference counting
- Single storage with multiple references

**Benefits:**
- Save storage space
- Faster synchronization
- Useful for backups

## Performance Metrics

### Measure Optimization Impact

```swift
struct PerformanceMetrics {
	// Operations
	let filesHashed: Int
	let filesCopied: Int
	let filesMoved: Int
	let filesSkipped: Int

	// Data
	let bytesHashed: Int64
	let bytesCopied: Int64
	let bytesSaved: Int64      // Via moves/skips

	// Time
	let hashingTime: TimeInterval
	let copyingTime: TimeInterval
	let movingTime: TimeInterval
	let totalTime: TimeInterval

	// Efficiency
	var copyEfficiency: Double {
		bytesSaved / (bytesCopied + bytesSaved)
	}
}
```

### Benchmarking

Compare optimized vs non-optimized:
- Track operations without optimization
- Track operations with optimization
- Measure time and data savings
- Identify bottlenecks

## Optimization Trade-offs

### Speed vs Accuracy

**Fast but risky:**
- Trust modification timestamps
- Skip hash verification
- Assume file systems are consistent

**Slow but accurate:**
- Always compute hashes
- Verify all operations
- Don't trust metadata

**Balanced approach:**
- Quick checks first (size, timestamp)
- Hash verification for critical files
- Configurable verification level

### Memory vs Disk

**Memory-intensive:**
- Cache all hashes in memory
- Build full directory tree in memory
- Faster but uses more RAM

**Disk-intensive:**
- Stream processing
- Minimal memory usage
- Slower but works with large datasets

### Complexity vs Maintainability

**Simple but inefficient:**
- Straightforward algorithms
- Easy to understand and maintain
- May be slower

**Complex but optimized:**
- Sophisticated move detection
- Block-level delta sync
- Harder to maintain

## Optimization Configuration

Allow users to tune optimization level:

```swift
struct OptimizationOptions {
	var moveDetection: Bool = true
	var hashCaching: Bool = true
	var parallelHashing: Bool = true
	var parallelCopying: Bool = true
	var maxConcurrentOperations: Int = 4
	var trustModificationTime: Bool = false
	var minFileSizeForMoveDetection: Int64 = 1024 * 1024  // 1MB
}
```

## Implementation Priorities

### Phase 1: Basic Optimization
1. Move detection (high impact)
2. Size-based quick comparison
3. Skip unchanged files

### Phase 2: Advanced Optimization
4. Hash caching
5. Parallel processing
6. Smart file comparison

### Phase 3: Expert Optimization
7. Block-level delta sync
8. Deduplication
9. Advanced caching strategies

## Open Questions

1. **Move detection accuracy**: How to handle hash collisions?
2. **Hash cache persistence**: Store cache between runs? Where?
3. **Parallel limits**: How many concurrent operations is optimal?
4. **Block size**: What block size for delta sync?
5. **Dedup strategy**: Hard links vs copy-on-write vs references?
6. **Cache invalidation**: When to invalidate hash cache?
7. **Optimization defaults**: What optimizations should be on by default?
8. **Platform-specific**: Use platform-specific optimizations (APFS cloning)?
9. **Network awareness**: Detect network drives and adjust strategy?
10. **Verification level**: How much verification is enough?
