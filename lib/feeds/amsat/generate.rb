#! /usr/bin/env ruby

require 'json'
require 'nokogiri'
require 'open-uri'
require_relative '../../hamdata'

tle_text = URI.open('https://www.amsat.org/tle/dailytle.txt').read

# Extract the satellite status table
def get_status_table
  status_html = URI.open('https://status.amsat.org/').read
  doc = Nokogiri::HTML(status_html)

  status_colors = {
    active: '#648fff',
    telemetry: '#ffb000',
    no_signal: '#dc267f',
    conflicting: '#fe6100',
    iss_crew: '#785ef0',
    unknown: 'C0C0C0' # note! No # in front of this one
  }

  # map of { "AMSAT OSCAR status page name" => "meta.json transponder id" }
  transponder_ids = {
    "AO-123_[FM]" => "AO-123-FM",
    "AO-129_[U/u_Digi]" => "AO-129-DIGI",
    "AO-7_[U/v]" => "AO-07-LIN-B",
    "AO-7_[V/a]" => "AO-07-LIN-A",
    "AO-73_[U/v]" => "AO-73-LIN",
    "AO-91_[FM]" => "AO-91-FM",
    "CAS-3H_[FM]" => "CAS-3H-FM",
    "CO-128_[VHF_Digi]" => "CO-128-DIGI",
    "FO-29_[V/u]" => "FO-29-LIN",
    "IO-86_[FM]" => "IO-86-FM",
    "ISS_[FM]" => "ISS-FM",
    "ISS_[VHF_Digi]" => "ISS-APRS",
    "JO-97_[U/v]" => "JO-97-LIN",
    "PO-101_[FM]" => "PO-101-FM",
    "QO-100_[NB]" => "QO-100-LIN-NB",
    "RS-44_[V/u]" => "RS-44-LIN",
    "SO-127_[FSK]" => "SO-127-DIGI",
    "SO-131_[V/u_FM]" => "SO-131-FM",
    "SO-132_[A/u_FM]" => "SO-132-FM",
    "SO-50_[FM]" => "SO-50-FM",
    "SONATE-2_[VHF_Digi]" => "SONATE-2-APRS",
  }

  # Satellite rows start with a right-aligned cell linking the "SAT_[Mode]" name
  rows = doc.xpath('//tr[td[1][@align="right"]/a]')
  warn "WARNING: no satellite rows found on the AMSAT status page; has its layout changed?" if rows.empty?

  transponder_statuses = 
    rows.map do |row|
      name = row.xpath('td[1]').text.strip

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

# Look up meta.json entries by key or alias (case-insensitive), so a satellite keeps
# its meta.json name even when AMSAT lists it differently, e.g. "LILACSAT-2" for
# CAS-3H, or "UNNE-1B (SO-131)" for SO-131
meta_keys_by_name = {}
metas.each do |key, meta|
  [key, *meta['aliases']].each { |n| meta_keys_by_name[n.downcase] ||= key }
end

def name_candidates(name)
  # "HADES-SA (SpinnyONE)" => ["HADES-SA (SpinnyONE)", "HADES-SA", "SpinnyONE"]
  [name, *name.match(/\A(.+?)\s*\((.+)\)\z/)&.captures]
end

tles = tle_text.split("\n").each_slice(3).to_a
amsat_names = tles.map(&:first)
used_meta_keys = []

data = tles.map do |amsat_name, tle1, tle2|
  number = tle2[2..6]

  meta_key = name_candidates(amsat_name).map { |n| meta_keys_by_name[n.downcase] }.compact.first
  # Don't let two TLE entries claim the same meta.json entry (or name)
  if meta_key && (used_meta_keys.include?(meta_key) || (meta_key != amsat_name && amsat_names.include?(meta_key)))
    meta_key = nil
  end
  used_meta_keys << meta_key if meta_key

  name = meta_key || amsat_name
  meta = meta_key && metas[meta_key]

  # Keep AMSAT's name searchable when we've renamed the satellite
  if meta && name != amsat_name && (meta['aliases'] || []).none? { |a| a.casecmp?(amsat_name) }
    meta['aliases'] = (meta['aliases'] || []) + [amsat_name]
  end

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
