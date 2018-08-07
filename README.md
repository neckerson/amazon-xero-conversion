# amazon-xero-conversion.rb
This simple Ruby script preps an Amazon transaction report for importing into
Xero as a CSV financial statement.

The first three rows of the report are removed. Dates are formatted as mm/dd/yy.
Finally, the file is saved as a comma-delimited .csv file, vs. the default tab-delimited format.
