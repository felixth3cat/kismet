#!/usr/bin/env ruby

# Very basic example for logging Kismet data to SQLite
# Would need to be expanded for more fields and better logging,
# contributions happily accepted

require 'socket'
require 'time'
require 'kismet'
require 'pp'
require "getopt/long"

include Getopt

host = "localhost"
port = 2501
$cards = []
$channel = 6

# Have not locked cards to a channel yet
$channel_locked = 0
# Have not found all the cards we wanted, yet
$cards_found = 0
# Found cards with UUIDs
$uuid_cards = {}

# card records by uuid
# contains { printed = 0/1, packets = #, last_packets = #, orig_packets = # }
$card_records = {}

# #of lines we've printed
$lines_per_header = 10
$num_printed = 10

def sourcecb(proto, fields)
	if fields["error"] != "0"
		puts "ERROR: Source #{fields['interface']} went into error state"
		$k.die
	end

	if $cards_found == 0
		if $cards.include?(fields["interface"])
			$uuid_cards[fields["interface"]] = fields["uuid"]
			puts "INFO: Found card UUID #{fields['uuid']} for #{fields['interface']}"
		end
	end

	if $channel_locked > 0
		# Add one per source
		# Once we've seen all the sources we expect to see twice, we start outputting
		# tracking data
		if $channel_locked > $cards.length * 2
			if $card_records.include?(fields["uuid"])
				# If we've seen this before, start the scan and print cycle
				r = $card_records[fields["uuid"]]

				r["printed"] = 0
				r["last_packets"] = r["packets"]
				r["packets"] = fields["packets"].to_i - r["orig_packets"]

				$card_records[fields["uuid"]] = r

				all_updated = 1
				$card_records.each { |cr|
					if cr[1]["printed"] == 1 or cr[1]["last_packets"] == 0
						all_updated = 0
						break
					end
				}

				if all_updated == 1
					str = ""
					total = 0
					lasttotal = 0
					best = 0

					$card_records.each { |cr|
						total = total + cr[1]["packets"]
						lasttotal = lasttotal + cr[1]["last_packets"]
						best = cr[1]["packets"] if cr[1]["packets"] > best
					}

					$card_records.each { |cr|
						cr[1]["printed"] = 1

						str = sprintf("%s  %6.6s %5.5s %8.8s %3d%%", str, "", cr[1]["packets"] - cr[1]["last_packets"], cr[1]["packets"], (cr[1]["packets"].to_f / best.to_f) * 100)
					}

					str = sprintf("%s %6.6s", str, total - lasttotal)

					if $num_printed == $lines_per_header
						puts
						hstr = ""

						$cards.each { |c|
							hstr = sprintf("%s  %6.6s %5.5s %8.8s %4.4s", hstr, c, "PPS", "Total", "Pcnt")
						}

						hstr = sprintf("%s %6.6s", hstr, "Combo")

						puts hstr

						$num_printed = 0
					end

					puts str

					$num_printed = $num_printed + 1

				end

			else
				r = {}
				r["printed"] = 0
				r["last_packets"] = 0
				r["orig_packets"] = fields["packets"].to_i
				r["packets"] = fields["packets"].to_i - r["orig_packets"]

				$card_records[fields["uuid"]] = r
			end
		else
			$channel_locked = $channel_locked + 1
		end
	end
end

def lockcback(text)
	if text != "OK"
		puts "ERROR: Failed to lock source to channel: #{text}"
		$k.die
		exit
	end
end

def sourcecback(text)
	if $uuid_cards.length != $cards.length
		puts "ERROR:  Couldn't find specified cards:"
		$cards.each { |c|
			puts "\t#{c}" if not $uuid_cards.include?(c)
		}

		$k.kill
	else
		$cards_found = 1

		puts "INFO: Locking #{$cards.join(", ")} to channel #{$channel}"

		$uuid_cards.each { |c|
			$k.command("HOPSOURCE #{c[1]} LOCK #{$channel}", Proc.new {|*args| lockcback(*args)})
		}

		$channel_locked = 1

		puts("INFO: Waiting for sources to settle on channel...")

	end
end

# No sources specified, print out the list of sources Kismet knows about
def nosourcecb(proto, fields)
	errstr = ""
	if fields['error'] != "0"
		errstr = "[IN ERROR STATE]"
	end
	puts "\t#{fields['interface']}\t#{fields['type']}\t#{errstr}"
end

# As soon as we get the ack for this command, kill the connection, because
# we're in no-sources-specified mode
def nosourceack()
	$k.kill
end

opt = Long.getopts(
	["--host", "", REQUIRED],
	["--port", "", REQUIRED],
	["--source", "-s", REQUIRED],
	["--channel", "-c", REQUIRED]
	)

if opt["host"]
	host = opt["host"]
end

if opt["port"]
	if opt["port"].match(/[^0-9]+/) != nil
		puts "ERROR:  Invalid port, expected number"
		exit
	end

	port = opt["port"].to_i
end

if opt["channel"]
	if opt["channel"].match(/[^0-9]+/) != nil
		puts "ERROR:  Invalid channel, expected number"
		exit
	end

	channel = opt["channel"].to_i
end

if opt["source"]
	if opt["source"].class != Array
		$cards = [opt["source"]]
	else
		$cards = opt["source"]
	end
end

puts "INFO: Kismet NIC Shootout"
puts "      Compare capture performance of multiple NICs"
puts

puts "INFO: Connecting to Kismet server on #{host}:#{port}"

$k = Kismet.new(host, port)
$k.connect()

$k.run()

if $cards.length == 0
	puts "ERROR:  No capture sources specified.  Available capture sources:"

	$k.subscribe("source", ["interface", "type", "username", "error"], Proc.new {|*args| nosourcecb(*args)}, Proc.new {|*args| nosourceack(*args)})

	$k.wait

	exit
end

puts "INFO: Testing sources #{$cards.join(", ")} on channel #{channel}"

# Print a header line
$num_printed = $lines_per_header

$k.subscribe("source", ["interface", "type", "username", "channel", "uuid", "packets", "error"], Proc.new {|*args| sourcecb(*args)}, Proc.new {|*args| sourcecback(*args)})

$k.wait


#$k = Kismet.new(host, port)
#
#$k.connect()
#
#$k.run()
#
#$k.subscribe("bssid", ["bssid", "type", "channel", "firsttime", "lasttime"], Proc.new {|*args| bssidcb(*args)})
#
#$k.wait()
