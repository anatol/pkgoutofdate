#!/usr/bin/ruby

require 'ostruct'
require 'optparse'
require 'thread'
require 'uri'

# Use abs packages to find current Arch versions
PACKAGES_DIR = '/var/abs'
VERSION_DELEMITER_REGEX = '[\._\-]'

$options = OpenStruct.new


OUTPUT_MUTEX = Mutex.new # serializes output to console
def log(message)
  OUTPUT_MUTEX.synchronize {
    # write directly to file descriptor to avoid client side buffering
    $stdout.write(message + "\n")
  }
end

WEIRD_CORRECT_TYPES = %w(.gz)
APP_INCORRECT_TYPES = %w(xml)
def correct_content_type?(type)
# TODO: cut '; charset=utf-8' from type

  # content type should be 'application/XXX' where XXX one of the archive types
  return false unless type
  return true if WEIRD_CORRECT_TYPES.include?(type)
  return false unless type.start_with?('application/')
  return !APP_INCORRECT_TYPES.include?(type[12..-1])
end

def url_exists?(url)
  uri = URI.parse(url)
  host = uri.host
  # cut leading www if any
  host = host[4..-1] if host.start_with?('www.')

  case
  when ['ladspa.org', 'download.videolan.org', 'launchpad.net'].include?(host)
    # this site returns content type == 'text' for files
    system("curl --head -s -o /dev/null --fail #{url}")
  when host =~ /.+?\.googlecode\.com/
    # thank you googlecode for this bug https://code.google.com/p/support/issues/detail?id=660
    header = "If-Modified-Since: Tue, 11 Dec #{Time.now.year+1} 10:10:24 GMT"
    system(%Q{curl --get -s -o /dev/null -w "%{http_code}" --header "#{header}" "#{url}" | grep -q 304})
  when %w(http https).include?(uri.scheme)
    type = `curl --head -L -s -o /dev/null -w "%{content_type}" "#{url}"`
    # TODO check response code here as well?
    correct_content_type?(type)
  when %w(ftp).include?(uri.scheme)
    system("curl --head -s -o /dev/null --fail #{url}")
  else
    false
  end
end

# parse version and supply list of possible next versions
def next_versions(ver, pkgname)
  result = []
  # version delimiters are [._-]
  split = ver.scan(/[\da-zA-Z]+|#{VERSION_DELEMITER_REGEX}/)

  # split is array of <number> <delemiter> <number> <develemiter> .. <number>
  reminder = []

  while true do
    numpart = split.pop
    unless numpart =~ /\d+/ then
      log "#{pkgname}: unable to parse version #{ver} numpart is #{numpart}" if $options.verbose
      break
    end

    next_numpart = numpart.to_i + 1
    result.push(split.join + next_numpart.to_s + reminder.join)

    break if split.empty?

    reminder.unshift("0")
    delimiter = split.pop
    unless delimiter =~ /#{VERSION_DELEMITER_REGEX}/ then
      log "{pkgname}: unable to parse version #{ver} delimiter is #{delimiter}" if $options.verbose
      break
    end
    reminder.unshift(delimiter)
  end

  return result
end

def process_pkgbuild(pkgpath)
  pkgcontent = IO.read(pkgpath).force_encoding("ISO-8859-1").encode("utf-8", replace: nil)

  # instead of doing crazy regexp parsing let's shell do it
  sources = `bash -c "./parse_pkgbuild.sh #{pkgpath}"`.split("\n")

  pkgname = sources.shift
  pkgver = sources.shift
  pkgver_regex = Regexp.new(pkgver.gsub(/#{VERSION_DELEMITER_REGEX}/, VERSION_DELEMITER_REGEX) + '\b')

  unless pkgname then
    log "Cannot parse #{pkgpath}, no pkgname" if $options.verbose
    return
  end

  return if sources.empty?

  sources.map! {|s| s.gsub(/(.*::)/, '') }

  sources.delete_if {|s| s !~ %r{^(http|https|ftp)://} }
  sources.delete_if {|s| s !~ pkgver_regex }

  if sources.empty? then
    log "#{pkgname}: cannot find source urls in #{pkgpath}" if $options.verbose
    return
  end

  source = sources[0]
  unless url_exists?(source) then
    log "#{pkgname}: file does not exist on the server - #{pkgver} => #{sources}" if $options.verbose
  end

  for newver in next_versions(pkgver, pkgname) do
    newurl = source.gsub(pkgver_regex, newver)
    if url_exists?(newurl) then
      if url_exists?(source.gsub(pkgver_regex, pkgver + '102.2'))
        # we requested some weird version and server responded positively. weird....
        log "#{pkgname}: server responses 'file exists' for invalid version #{newurl}" if $options.verbose
      else
        log "#{pkgname}: new version found - #{pkgver} => #{newver}"
      end

      break
    end
  end
end

# list of PKBUILD files to process
def find_all_packages(repos_dir, quick_package)
  result = []

  for path in Dir.glob(repos_dir + '/*/*') do
    pkgname = File.basename(path)

    if quick_package and (quick_package != pkgname) then
      next
    end

    # skip if this package presents in testing
    testing = '/testing/' + pkgname
    next if File.exists?(repos_dir + testing) and not path.end_with?(testing)
    testing = '/community-testing/' + pkgname
    next if File.exists?(repos_dir + testing) and not path.end_with?(testing)

    pkgpath = path + '/PKGBUILD'
    next unless File.exists?(pkgpath)

    result << pkgpath
  end

  return result
end

QUEUE_MUTEX = Mutex.new # protects queue of PKGBUILD to process
def work_thread(queue)
  while true do
    pkg = nil
    QUEUE_MUTEX.synchronize {
      pkg = queue.pop
    }
    return unless pkg

    process_pkgbuild(pkg)
  end
end

unless File.directory? PACKAGES_DIR
  puts "Abs directory #{PACKAGES_DIR} does not exist"
  exit 1
end


OptionParser.new do |opts|
  opts.banner = <<-eos
    Tool that checks whether new releases available for Arch packages.
    Tool iterates over ABS directory, extracts downloadable url and tries to probe
    X.Y.Z+1, X.Y+1.0 and X+1.0.0 versions. If server responses OK for such urls then
    the tool assumes a new release available.

    Usage: pkgoutofdate.rb [options] [package_name]
  eos

  # default value
  $options.threads_num = 12

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    $options.verbose = v
  end

  opts.on("--threads_num T", Integer, "Number of thread used for URL polling") do |t|
    $options.threads_num = t
  end
end.parse!

# Instead of checking all ABS tree we could quickly check only 1 package
quick_package = ARGV[0]

queue = find_all_packages(PACKAGES_DIR, quick_package)
if queue.empty? then
  log "No packages found!"
  exit 1
end

threads = []
threads_num = [$options.threads_num, queue.size].min
for i in 1..threads_num do
  threads << Thread.new { work_thread(queue) }
end
threads.each { |thr| thr.join }
