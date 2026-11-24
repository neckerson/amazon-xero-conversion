#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Amazon settlement reports (tab-delimited "Flat File V2" .txt) into
# comma-delimited CSVs for import into Xero as bank statements.
#
#   transactions/standard/*.txt  ->  converted/standard/*.csv
#   transactions/invoiced/*.txt  ->  converted/invoiced/*.csv
#   transactions/*.txt           ->  converted/*.csv   (files added by hand)
#
# For each file it drops the settlement summary line, rewrites posted-date as
# MM/DD/YYYY, and checks that the transaction amounts add up to the payout.
#
# Usage: ruby amazon-statement-conversion.rb [file.txt ...]   (no arguments = all files)

require 'bigdecimal'
require 'csv'
require 'date'
require 'fileutils'

ROOT = File.expand_path(__dir__)
IN_DIR = File.join(ROOT, 'transactions')
OUT_DIR = File.join(ROOT, 'converted')

# The Xero import mapping depends on these columns, so stop if Amazon changes them.
EXPECTED_HEADER = %w[
  settlement-id settlement-start-date settlement-end-date deposit-date total-amount currency
  transaction-type order-id merchant-order-id adjustment-id shipment-id marketplace-name
  amount-type amount-description amount fulfillment-id posted-date posted-date-time
  order-item-code merchant-order-item-id merchant-adjustment-item-id sku quantity-purchased promotion-id
].freeze

class ConversionError < StandardError; end

def money(value, where)
  BigDecimal(value.to_s.delete('$,').strip.then { |v| v.empty? ? '0' : v })
rescue ArgumentError
  raise ConversionError, "#{where}: amount #{value.inspect} is not a number"
end

def convert(input, output)
  rows = CSV.read(input, col_sep: "\t", encoding: 'bom|utf-8', liberal_parsing: true)
  header = rows.shift
  raise ConversionError, 'file is empty' if header.nil?
  unless header == EXPECTED_HEADER
    raise ConversionError, "unexpected columns; Amazon may have changed the format.\n    Got: #{header.join(', ')}"
  end

  col = header.each_with_index.to_h
  summary = rows.shift
  if summary.nil? || summary[col['total-amount']].to_s.empty? || !summary[col['transaction-type']].to_s.empty?
    raise ConversionError, 'line 2 is not the settlement summary line'
  end

  total = money(summary[col['total-amount']], 'line 2')
  sum = BigDecimal('0')
  rows.each_with_index do |row, i|
    line = i + 3
    # Amazon omits trailing empty fields on some fee rows; pad them back out.
    raise ConversionError, "line #{line} has #{row.size} columns, expected #{header.size}" if row.size > header.size

    row.fill(nil, row.size...header.size)

    sum += money(row[col['amount']], "line #{line}")
    posted = row[col['posted-date']]
    begin
      row[col['posted-date']] = Date.strptime(posted, '%Y-%m-%d').strftime('%m/%d/%Y')
    rescue ArgumentError, TypeError
      raise ConversionError, "line #{line}: posted-date #{posted.inspect} is not YYYY-MM-DD"
    end
  end

  FileUtils.mkdir_p(File.dirname(output))
  tmp = "#{output}.part"
  CSV.open(tmp, 'w') do |csv|
    csv << header
    rows.each { |row| csv << row }
  end
  File.rename(tmp, output)

  [rows.size, total, sum]
end

inputs = ARGV.empty? ? Dir.glob(File.join(IN_DIR, '**', '*.txt')).sort : ARGV.map { |a| File.expand_path(a) }
abort "No .txt files found in #{IN_DIR}" if inputs.empty?

failures = 0
mismatches = 0
inputs.each do |input|
  relative = input.start_with?("#{IN_DIR}/") ? input.delete_prefix("#{IN_DIR}/") : File.basename(input)
  output = File.join(OUT_DIR, relative.sub(/\.txt\z/, '.csv'))
  begin
    count, total, sum = convert(input, output)
    note = ''
    if sum != total
      mismatches += 1
      note = "  WARNING: rows add up to #{format('%.2f', sum)}, settlement total is #{format('%.2f', total)}"
    end
    puts format('  ok    %-32s %5d rows  $%10s%s', relative, count, format('%.2f', total), note)
  rescue ConversionError, CSV::MalformedCSVError, Errno::ENOENT => e
    failures += 1
    FileUtils.rm_f("#{output}.part")
    warn "  FAIL  #{relative}: #{e.message}"
  end
end

puts "Converted #{inputs.size - failures} of #{inputs.size} file(s) into #{OUT_DIR.delete_prefix("#{ROOT}/")}/"
warn "#{mismatches} file(s) do not add up to their settlement total; check them before importing." if mismatches.positive?
exit(failures.positive? ? 1 : 0)
