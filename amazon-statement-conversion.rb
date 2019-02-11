require 'date'
require 'csv'

i = 0
hdr = ["Date", "Order ID", "SKU", "Transaction type", "Payment Type", "Payment Detail", "Amount", "Quantity", "Product Title"]


# Create the output file
CSV.open('transactions.csv', 'w', write_headers: true, headers: hdr, col_sep: ",") do |csv|

  # Open the input file (a tab-separated .txt file) and ignore the first three
  # rows, since they aren't useful
  CSV.open('report.txt', 'r', headers: hdr, col_sep: "\t" ).each do |row|
    if i > 3

      # The transaction report is currently formatting date as 'Jan 1, 2018'
      # which is useless for our purposes. Using the methods below, converts
      # the time into a date, then back into the proper format
      row['Date'] = Date.strptime(row['Date'], '%B %d, %Y').strftime '%m/%d/%Y'
      csv << row
    end
    i += 1
  end
end
