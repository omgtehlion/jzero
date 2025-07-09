# jzero

A high-performance command-line JSON viewer that can handle gigabytes of JSON data with ease. Built with Zig for maximum performance and minimal memory footprint.

## Features

- **High Performance**: Handles gigabytes of JSON data efficiently
- **JSON5 Support**: Full support for JSON5 format including comments, trailing commas, and relaxed syntax
- **Streaming JSON Lines**: Process JSONL/NDJSON files with multiple JSON objects seapated by newlines
- **Comment Support**: View and navigate JSON files with JavaScript-style comments (`//` and `/* */`)
- **Flexible Parsing**: Handles malformed JSON gracefully with error reporting
- **Interactive Navigation**: Vim-like keybindings for intuitive browsing
- **Search Functionality**: Fast text search with match highlighting
- **Cross-Platform**: Supports Windows and Linux
- **Memory Efficient**: Streaming parser with chunked data loading
- **Syntax Highlighting**: Color-coded JSON elements for better readability
- **Collapsible Nodes**: Expand/collapse objects and arrays for better navigation

## Installation

### Prerequisites

- Zig 0.14 or later
- Linux: `ncursesw` development library
- Windows: No additional dependencies required

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.