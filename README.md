# amazon-xero-conversion.rb
This simple Ruby script preps an Amazon transaction report for importing into
Xero as a CSV financial statement.

The first three rows of the report are removed. Dates are formatted as mm/dd/yy.
Amazon is always changing the output of their report, and recently have added
USD '$' in the Amount column. These symbols are stripped out and any empty
fields are replaced with 0.00
Finally, the file is saved as a comma-delimited .csv file, vs. the default tab-delimited format.
