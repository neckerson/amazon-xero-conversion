#!/usr/bin/env ruby
# frozen_string_literal: true

# Downloads Amazon settlement reports ("All Statements" > "Download Flat File V2"
# in Seller Central) through the Selling Partner API and files them by account type:
#
#   transactions/standard/<report-id>.txt   Standard Orders
#   transactions/invoiced/<report-id>.txt   Invoiced Orders (Amazon Business pay-by-invoice)
#
# Read-only: it lists and downloads reports and looks up one order per settlement.
# It never changes anything in Seller Central.
#
# Run with --help for options.

require 'date'
require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require 'time'
require 'stringio'
require 'uri'
require 'zlib'

ROOT = File.expand_path(__dir__)
REPORT_TYPE = 'GET_V2_SETTLEMENT_REPORT_DATA_FLAT_FILE_V2'
LISTING_WINDOW_DAYS = 90 # Amazon only lists reports created in the last 90 days
TOKEN_URL = 'https://api.amazon.com/auth/o2/token'
DEFAULT_ENV_FILE = File.expand_path('~/.config/amazon-sp-api/stopmotion-explosion.env')
TYPES = %w[standard invoiced].freeze

class FetchError < StandardError; end

# ---------- options ----------

options = {
  from: Date.today - LISTING_WINDOW_DAYS + 1,
  to: Date.today,
  types: TYPES,
  dry_run: false,
  force: false,
  env_file: ENV.fetch('SP_API_ENV_FILE', DEFAULT_ENV_FILE)
}

parser = OptionParser.new do |o|
  o.banner = "Usage: ruby fetch-settlements.rb [options]\n\n" \
             "Selects settlements by the date the statement period ENDED (the\n" \
             "right-hand date of the period on the All Statements page).\n\n"
  o.on('--from DATE', 'First period end date to include, YYYY-MM-DD (default: 90 days ago)') { |v| options[:from] = Date.iso8601(v) }
  o.on('--to DATE', 'Last period end date to include, YYYY-MM-DD (default: today)') { |v| options[:to] = Date.iso8601(v) }
  o.on('--type TYPE', TYPES + ['all'], 'standard, invoiced or all (default: all)') { |v| options[:types] = v == 'all' ? TYPES : [v] }
  o.on('--dry-run', 'List what would be downloaded without saving anything') { options[:dry_run] = true }
  o.on('--force', 'Download again even if the file is already saved') { options[:force] = true }
  o.on('--env FILE', "Credentials file (default: #{DEFAULT_ENV_FILE}, or $SP_API_ENV_FILE)") { |v| options[:env_file] = File.expand_path(v) }
  o.on('-h', '--help', 'Show this help') { puts o; exit }
end

begin
  parser.parse!
rescue OptionParser::ParseError, Date::Error => e
  warn "#{e.message}\n\n#{parser}"
  exit 2
end
abort '--from is after --to' if options[:from] > options[:to]

# ---------- SP-API client ----------

class SpApi
  RETRYABLE = [429, 500, 502, 503, 504].freeze

  def initialize(env_file)
    @cfg = load_env(env_file)
    @endpoint = URI(@cfg.fetch('SP_API_ENDPOINT', 'https://sellingpartnerapi-na.amazon.com'))
    @marketplace = @cfg.fetch('SP_API_MARKETPLACE_ID', 'ATVPDKIKX0DER')
    @token = nil
    @token_expires = Time.at(0)
  end

  attr_reader :marketplace

  def get(path, params = {})
    uri = @endpoint.dup
    uri.path = path
    uri.query = URI.encode_www_form(params) unless params.empty?
    with_retries("GET #{path}") do
      req = Net::HTTP::Get.new(uri)
      req['x-amz-access-token'] = access_token
      req['user-agent'] = 'amazon-xero-conversion/1.0 (Language=Ruby)'
      http(uri, req)
    end
  end

  # Report documents are served from a pre-signed S3 URL; no auth header.
  def download(url)
    uri = URI(url)
    with_retries('download report document') { http(uri, Net::HTTP::Get.new(uri), raw: true) }
  end

  private

  def load_env(path)
    raise FetchError, "Credentials file not found: #{path}" unless File.exist?(path)

    cfg = {}
    File.foreach(path) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#') || !line.include?('=')

      key, value = line.split('=', 2)
      cfg[key.strip] = value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
    end
    missing = %w[SP_API_CLIENT_ID SP_API_CLIENT_SECRET SP_API_REFRESH_TOKEN].reject { |k| cfg[k].to_s != '' }
    raise FetchError, "Missing in #{path}: #{missing.join(', ')}" unless missing.empty?

    cfg
  end

  def access_token
    return @token if @token && Time.now < @token_expires

    uri = URI(TOKEN_URL)
    req = Net::HTTP::Post.new(uri)
    req.set_form_data('grant_type' => 'refresh_token', 'refresh_token' => @cfg['SP_API_REFRESH_TOKEN'],
                      'client_id' => @cfg['SP_API_CLIENT_ID'], 'client_secret' => @cfg['SP_API_CLIENT_SECRET'])
    status, body = http(uri, req)
    data = JSON.parse(body) rescue {}
    # Never echo the request or token; only Amazon's error code and description.
    raise FetchError, "Login with Amazon token request failed (#{status}): #{data.values_at('error', 'error_description').compact.join(' - ')}" unless status == 200

    @token = data.fetch('access_token')
    @token_expires = Time.now + data.fetch('expires_in', 3600).to_i - 120
    @token
  end

  def http(uri, req, raw: false)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 120) { |h| h.request(req) }
    [res.code.to_i, raw ? res.body.b : res.body.to_s]
  end

  # Some endpoints allow only about one call a minute once their burst is used
  # (report documents, for example), so throttled calls wait up to ~65s each.
  def with_retries(label, attempts: 8)
    attempts.times do |i|
      status, body = begin
        yield
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError, OpenSSL::SSL::SSLError => e
        [0, e.message]
      end
      return body if status == 200

      unless (status.zero? || RETRYABLE.include?(status)) && i < attempts - 1
        raise FetchError, "#{label} failed (#{status}): #{body.to_s[0, 500]}"
      end

      wait = status == 429 ? [5 * 2**i, 65].min : [2**i, 30].min
      warn "  (#{status.zero? ? 'network error' : "Amazon #{status}"} on #{label.split('/').first(4).join('/')}; retrying in #{wait}s)"
      sleep(wait + rand)
    end
  end
end

# ---------- settlement helpers ----------

EXPECTED_HEADER = %w[
  settlement-id settlement-start-date settlement-end-date deposit-date total-amount currency
  transaction-type order-id merchant-order-id adjustment-id shipment-id marketplace-name
  amount-type amount-description amount fulfillment-id posted-date posted-date-time
  order-item-code merchant-order-item-id merchant-adjustment-item-id sku quantity-purchased promotion-id
].freeze

def list_reports(api, created_since, created_until)
  reports = []
  params = { 'reportTypes' => REPORT_TYPE, 'processingStatuses' => 'DONE', 'pageSize' => 100,
             'createdSince' => created_since.utc.iso8601, 'createdUntil' => created_until.utc.iso8601 }
  loop do
    data = JSON.parse(api.get('/reports/2021-06-30/reports', params))
    reports.concat(data.fetch('reports', []))
    break unless data['nextToken']

    params = { 'nextToken' => data['nextToken'] } # Amazon requires nextToken on its own
  end
  reports
end

def download_report(api, report)
  doc = JSON.parse(api.get("/reports/2021-06-30/documents/#{report.fetch('reportDocumentId')}"))
  body = api.download(doc.fetch('url'))
  body = Zlib::GzipReader.new(StringIO.new(body)).read if doc['compressionAlgorithm'] == 'GZIP'
  body.force_encoding('UTF-8')
  raise FetchError, "Report #{report['reportId']} is not valid UTF-8" unless body.valid_encoding?

  body
end

# Parses just enough of the flat file to classify and sanity-check it.
def inspect_settlement(report_id, body)
  lines = body.lines.map { |l| l.chomp.split("\t", -1) }
  header = lines[0]
  unless header == EXPECTED_HEADER
    raise FetchError, "Report #{report_id} has unexpected columns; Amazon may have changed the format. " \
                      "Check amazon-statement-conversion.rb before importing.\nGot: #{header&.join(', ')}"
  end

  col = header.each_with_index.to_h
  summary = lines[1] || []
  rows = lines[2..] || []
  {
    settlement_id: summary[col['settlement-id']],
    start: summary[col['settlement-start-date']],
    end: summary[col['settlement-end-date']],
    total: summary[col['total-amount']],
    rows: rows.size,
    first_order_id: rows.map { |r| r[col['order-id']] }.find { |id| id.to_s.match?(/\A\d{3}-\d{7}-\d{7}\z/) }
  }
end

# Amazon does not label a settlement Standard or Invoiced, so look up one of its
# orders: pay-by-invoice orders have PaymentMethodDetails ["Invoice"].
def classify(api, info)
  if info[:first_order_id]
    order = JSON.parse(api.get("/orders/v0/orders/#{info[:first_order_id]}")).fetch('payload', {})
    return [Array(order['PaymentMethodDetails']).include?('Invoice') ? 'invoiced' : 'standard', 'order payment method']
  end

  # No orders (fees or adjustments only). Fall back to the closing time: Standard
  # settlements have closed around 15:11 UTC and Invoiced around 01:17 UTC.
  hour = Time.parse(info[:end].to_s).utc.hour
  [hour < 8 ? 'invoiced' : 'standard', 'closing time (no orders to check)']
end

def existing_path(report_id)
  TYPES.map { |t| File.join(ROOT, 'transactions', t, "#{report_id}.txt") }.find { |p| File.exist?(p) }
end

def write_atomically(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  tmp = "#{path}.part"
  File.binwrite(tmp, body)
  File.rename(tmp, path)
end

# ---------- main ----------

begin
  api = SpApi.new(options[:env_file])

  oldest_listable = Date.today - LISTING_WINDOW_DAYS + 1
  from = options[:from]
  if from < oldest_listable
    warn "Note: Amazon's API only lists settlements from the last #{LISTING_WINDOW_DAYS} days, so this " \
         "covers periods ending #{oldest_listable} onwards. Download anything older from Seller Central " \
         '(Payments > All Statements > Download Flat File V2).'
    from = oldest_listable
  end
  abort "Nothing to fetch: #{options[:to]} is older than #{oldest_listable}." if options[:to] < from

  # A report is created when its period closes, so list by creation date with a few
  # days' slack, then filter on the period end date itself.
  created_since = [from.to_time, Time.now - ((LISTING_WINDOW_DAYS - 1) * 86_400)].max
  created_until = [(options[:to] + 4).to_time, Time.now].min
  reports = list_reports(api, created_since, created_until)
            .select { |r| (from..options[:to]).cover?(Time.parse(r['dataEndTime']).utc.to_date) }
            .uniq { |r| r['reportId'] }
            .sort_by { |r| r['dataEndTime'] }

  puts "#{reports.size} settlement(s) with periods ending #{from} to #{options[:to]}#{options[:dry_run] ? ' (dry run)' : ''}"
  counts = Hash.new(0)
  seen_settlements = {}

  reports.each do |r|
    id = r.fetch('reportId')
    period = "#{r['dataStartTime'][0, 10]} to #{r['dataEndTime'][0, 10]}"
    if (path = existing_path(id)) && !options[:force]
      puts "  skip  #{id}  #{period}  already saved (#{path.delete_prefix("#{ROOT}/")})"
      counts[:skipped] += 1
      next
    end

    body = download_report(api, r)
    info = inspect_settlement(id, body)
    if (dup = seen_settlements[info[:settlement_id]])
      puts "  skip  #{id}  #{period}  same settlement #{info[:settlement_id]} as report #{dup}"
      next
    end
    seen_settlements[info[:settlement_id]] = id

    type, basis = classify(api, info)
    unless options[:types].include?(type)
      counts[:other_type] += 1
      next
    end

    line = format('  %-5s %s  %s  %-8s $%10s  %4d rows  [%s]', options[:dry_run] ? 'would' : 'saved', id, period, type, info[:total], info[:rows], basis)
    unless options[:dry_run]
      FileUtils.rm_f(existing_path(id)) if options[:force] # in case it was filed under the other type
      write_atomically(File.join(ROOT, 'transactions', type, "#{id}.txt"), body)
    end
    puts line
    counts[type] += 1
  end

  summary = TYPES.map { |t| "#{counts[t]} #{t}" }.join(', ')
  summary += ", #{counts[:skipped]} already saved" if counts[:skipped].positive?
  summary += ", #{counts[:other_type]} of the other type ignored" if counts[:other_type].positive?
  puts "Done: #{summary}."
  puts 'Next: ruby amazon-statement-conversion.rb' if !options[:dry_run] && (counts['standard'] + counts['invoiced']).positive?
rescue FetchError, JSON::ParserError, KeyError => e
  warn "Error: #{e.message}"
  exit 1
end
