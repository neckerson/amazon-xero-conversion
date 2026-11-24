# amazon-xero-conversion

Downloads Amazon settlement reports and converts them into CSVs for importing into Xero as bank statements.

These are the reports on Seller Central's **Payments > All Statements** page ("Download Flat File V2"). Amazon keeps two separate settlement streams, chosen by the **Account Type** dropdown on that page, and this tool keeps them in separate folders:

| Folder | Account type | What it is |
|---|---|---|
| `standard/` | Standard Orders | Normal orders, refunds and FBA fees, settled every 14 days |
| `invoiced/` | Invoiced Orders | Amazon Business pay-by-invoice orders, on their own schedule |

## Usage

```
ruby fetch-settlements.rb --from 2026-10-01 --to 2026-10-31   # download
ruby amazon-statement-conversion.rb                              # convert
```

Then import the CSVs from `converted/standard/` and `converted/invoiced/` into Xero.

```
.
├── fetch-settlements.rb            # downloads reports via Amazon's Selling Partner API
├── amazon-statement-conversion.rb  # converts .txt reports to Xero CSVs
├── transactions/
│   ├── standard/<report-id>.txt
│   └── invoiced/<report-id>.txt
└── converted/
    ├── standard/<report-id>.csv
    └── invoiced/<report-id>.csv
```

## fetch-settlements.rb

Downloads finished settlement reports whose statement period **ended** between `--from` and `--to` (inclusive). That is the right-hand date of the period on the All Statements page. A statement that is still open ("– Present") has no report yet.

| Option | Meaning |
|---|---|
| `--from YYYY-MM-DD` | First period end date to include (default: 90 days ago) |
| `--to YYYY-MM-DD` | Last period end date to include (default: today) |
| `--type standard\|invoiced\|all` | Which account type to save (default: all) |
| `--dry-run` | Show what would be downloaded; save nothing |
| `--force` | Download again even if already saved |
| `--env FILE` | Credentials file (default `~/.config/amazon-sp-api/stopmotion-explosion.env`, or `$SP_API_ENV_FILE`) |

- **90-day limit.** Amazon's API only lists settlements from the last 90 days. For anything older, download the Flat File V2 from Seller Central and put it in `transactions/standard/` or `transactions/invoiced/` yourself. Run the script at least every couple of months so nothing ages out.
- **Safe to rerun.** Reports already saved are skipped, so running the same range twice downloads nothing new. Files are named by Amazon's report ID, the same name Seller Central gives the download.
- **Slow on large ranges.** Amazon allows about one report download per minute after a short burst. The script waits and retries on its own, and if it stops, rerunning picks up where it left off.
- **How it sorts the two types.** Amazon doesn't label a settlement as Standard or Invoiced, so the script looks up one order from each settlement: pay-by-invoice orders have payment method "Invoice". A settlement with no orders (fees only) falls back to its closing time; Standard has closed around 15:11 UTC and Invoiced around 01:17 UTC. Each line of output says which method was used.
- **Read-only.** It lists and downloads reports and reads one order per settlement. It never changes anything in Seller Central.
- **Credentials.** The file needs `SP_API_CLIENT_ID`, `SP_API_CLIENT_SECRET` and `SP_API_REFRESH_TOKEN` (optional `SP_API_ENDPOINT`, `SP_API_MARKETPLACE_ID`). The app needs the Finance and Accounting role, plus Inventory and Order Tracking for the order lookup. Secrets are never printed.

## amazon-statement-conversion.rb

Converts every `.txt` under `transactions/` (including its subfolders) into a `.csv` at the same path under `converted/`. Pass file paths to convert only those. For each file it:

- removes the settlement summary line (line 2)
- rewrites `posted-date` as MM/DD/YYYY
- pads rows where Amazon left off trailing empty columns
- writes a comma-delimited CSV with the same columns as the report

It also checks each file and stops with a clear message if:

- the columns are not the expected Flat File V2 layout (if Amazon changes the format, the Xero import mapping would break)
- a date or amount can't be read

It warns, but still converts, if the transaction amounts don't add up to the settlement's payout total.

Existing CSVs are overwritten. The exit status is non-zero if any file failed.

Requires Ruby 3.x and only its standard library.
