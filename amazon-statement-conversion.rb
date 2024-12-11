require 'date'
require 'csv'
require 'fileutils'

# Ensure the output directory exists
FileUtils.mkdir_p('converted')

# Headers for processing
hdr = ["settlement-id", "settlement-start-date", "settlement-end-date", "deposit-date", "total-amount", "currency", "transaction-type", "order-id", "merchant-order-id", "adjustment-id", "shipment-id", "marketplace-name", "amount-type", "amount-description", "amount","fulfillment-id","posted-date", "posted-date-time", "order-item-code", "merchant-order-item-id", "merchant-adjustment-item-id", "sku", "quantity-purchased", "promotion-id"]

# Process all .txt files in the transactions directory
Dir.glob('transactions/*.txt') do |input_file|
  # Get the base filename without extension
  base_filename = File.basename(input_file, '.txt')
  
  # Create the output filename
  output_file = File.join('converted', "#{base_filename}.csv")
  
  # Process each file
  CSV.open(output_file, 'w', write_headers: true, headers: hdr, col_sep: ",") do |csv|
    i = 0
    
    # Open and process the input file
    CSV.open(input_file, 'r', headers: hdr, col_sep: "\t").each do |row|
      if i >= 2
        # Format the date
        row['posted-date'] = Date.strptime(row['posted-date'], '%Y-%m-%d').strftime '%m/%d/%Y'
        
        # Write the processed row
        csv << row
      end
      i += 1
    end
  end
end
