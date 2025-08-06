#! /usr/bin/env ruby

require 'json'
require 'nokogiri'
require 'open-uri'
require_relative '../../hamdata'

tle_text = URI.open('https://www.amsat.org/tle/dailytle.txt').read

# Extract the satellite status table
def get_status_table
  status_html = URI.open('https://www.amsat.org/status/').read
  doc = Nokogiri::HTML(status_html)

  status_colors = {
    active: '#4169E1',
    telemetry: 'yellow',
    no_signal: 'red',
    conflicting: 'orange',
    iss_crew: '#9900FF',
    unknown: 'C0C0C0' # note! No # in front of this one
  }

  # map of { "AMSAT OSCAR status page name" => "meta.json transponder id" }
  transponder_ids = {
    "AO-123" => "AO-123-FM",
    "AO-7[A]" => "AO-07-LIN-A",
    "AO-7[B]" => "AO-07-LIN-B",
    "AO-73" => "AO-73-LIN",
    "AO-91" => "AO-91-FM",
    # "BHUTAN-1" => "todo",
    # "CAS-4A" => "todo",
    # "CAS-4B" => "todo",
    "FO-29" => "FO-29-LIN",
    "HADES-ICM_(SO-125)" => "SO-125-FM",
    "IO-117" => "IO-117-DIGI",
    "IO-86" => "IO-86-FM",
    "ISS-DATA" => "ISS-APRS",
    "ISS-FM" => "ISS-FM",
    "JO-97" => "JO-97-LIN",
    "LilacSat-2" => "CAS-3H-FM",
    "MESAT1" => "MESAT1-LIN",
    "MO-122" => "MO-122-LIN",
    # "NO-44" => "todo",
    "PO-101[FM]" => "PO-101-FM",
    "QO-100_NB" => "QO-100-LIN-NB",
    "RS-44" => "RS-44-LIN",
    "SO-121" => "SO-121-FM",
    "SO-124" => "SO-124-FM",
    "SO-50" => "SO-50-FM",
    "SONATE-2 APRS" => "SONATE-2-APRS",
    # "TO-108" => "todo",
    # "UO-11[B]" => "todo",
    # "UVSQ-SAT" => "todo",
    "XW-2B" => "XW-2B-LIN",
    "XW-2C" => "XW-2C-LIN",
    # "XW-2D" => "todo",
  }

  transponder_statuses = 
    doc.xpath('/html/body/center[4]/table/tr').map do |row|
      name = row.xpath('td[1]').text.strip
      next if name == 'Name' # skip header row

      transponder_id = transponder_ids[name]
      next unless transponder_id

      status_counts = status_colors.map do |status, color|
        [status, row.xpath("td[@bgcolor='#{color}']").count]
      end.to_h

      active_count = status_counts[:active] + status_counts[:iss_crew] + status_counts[:conflicting] / 2
      inactive_count = status_counts[:telemetry] + status_counts[:no_signal] + status_counts[:conflicting] / 2
      total_count = active_count + inactive_count

      active_rate = active_count.to_f / total_count

      if total_count < 3
        status = :unknown
      elsif active_rate > 0.5
        status = :active
      elsif active_rate < 0.25
        status = :inactive
      else
        status = :conflicting
      end

      [transponder_id, status]
    end.compact.to_h

  transponder_statuses
end

def best_transponder_status(statuses)
  return :unknown if statuses.empty?

  if statuses.include?(:active)
    :active
  elsif statuses.include?(:conflicting)
    :conflicting
  elsif statuses.include?(:inactive)
    :inactive
  else
    :unknown
  end
end

transponder_statuses = get_status_table

meta_path = File.join(File.dirname(__FILE__), 'meta.json')
metas = JSON.load(File.read(meta_path))

# Split into 3-line chunks
data = tle_text.split("\n").each_slice(3).map do |name, tle1, tle2|
  number = tle2[2..6]
  meta = metas[name]

  # HACK: Fix the drag term for QO-100, so that SatelliteKit on iOS can parse it
  if tle1[54..60] == '00000 0'
    tle1[54..60] = '00000-0'
  end

  all_transponder_statuses = []
  if meta && meta['transponders']
    meta['transponders'].each do |transponder|
      status = transponder_statuses[transponder['id']]
      all_transponder_statuses << status
      transponder.merge!('status' => status || 'unknown')
    end
  end

  result = {
    'name' => name,
    'number' => number,
    'tle' => [tle1, tle2],
    'status' => best_transponder_status(all_transponder_statuses)
  }

  result['meta'] = meta if meta
  result
end


output = {
  'updated' => Time.now.utc.iso8601,
  'data' => data
}

Hamdata.open_output_file('amsat/satellites.json') do |f|
  f.puts JSON.generate(output)
end

Hamdata.open_output_file('amsat/dailytle.txt') do |f|
  f.puts tle_text
end
