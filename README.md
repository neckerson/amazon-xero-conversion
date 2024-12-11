# amazon-xero-conversion.rb

This Ruby script batch processes Amazon transaction reports and prepares them for importing into Xero as CSV financial statements.

## Features

- Processes multiple Amazon transaction reports in a single run
- Converts tab-delimited .txt files to comma-delimited .csv files
- Reformats dates to mm/dd/yy format for Xero compatibility
- Handles Amazon report format changes (e.g. USD '$' symbols in Amount column)
- Replaces empty fields with 0.00
- Preserves original filenames when creating converted files

## Directory Structure

```
.
├── amazon-xero-conversion.rb
├── transactions/           # Place Amazon transaction .txt files here
└── converted/             # Output directory for processed .csv files
```

## Usage

1. Create a `transactions` directory in the same folder as the script
2. Place all Amazon transaction .txt files in the `transactions` directory
3. Run the script:
   ```
   ruby amazon-xero-conversion.rb
   ```
4. Find your converted files in the `converted` directory

## File Processing

The script performs the following operations on each file:
- Removes the first three rows of the report
- Reformats dates as mm/dd/yy
- Strips any USD '$' symbols from the Amount column
- Replaces empty fields with 0.00
- Saves the file as a comma-delimited .csv file

## Notes

Amazon frequently updates their report format. This script handles recent changes including:
- USD '$' symbols in the Amount column
- Empty field handling
- Tab-delimited input format

If Amazon changes their report format again, you may need to update the script accordingly.
