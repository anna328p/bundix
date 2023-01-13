require 'bundler'
require 'json'
require 'open-uri'
require 'open3'
require 'pp'

require_relative 'bundix/version'
require_relative 'bundix/source'
require_relative 'bundix/nixer'

class Bundix
  NIX_INSTANTIATE = 'nix-instantiate'
  NIX_PREFETCH_URL = 'nix-prefetch-url'
  NIX_PREFETCH_GIT = 'nix-prefetch-git'
  NIX_HASH = 'nix-hash'
  NIX_SHELL = 'nix-shell'

  SHA256_32 = %r(^[a-z0-9]{52}$)

  attr_reader :options

  attr_accessor :fetcher

  class Dependency < Bundler::Dependency
    def initialize(name, version, options={}, &blk)
      super(name, version, options, &blk)
      @bundix_version = version
    end

    attr_reader :version
  end

  def initialize(options)
    @options = { quiet: false, tempfile: nil }.merge(options)
    @fetcher = Fetcher.new
  end

  def convert
    lock = parse_lockfile
    dep_cache = build_depcache(lock)

    gems = Hash.new { |h, k| h[k] = [] }

    # reverse so git comes last
    lock.specs.reverse_each do |spec|
      gem = convert_spec(spec, dep_cache)
      if spec.dependencies.any?
        gem[:dependencies] = spec.dependencies.map(&:name) - ['bundler']
      end
      gems[spec.name] << gem
    end

    gems.map do |name, variants|
      primary = nil
      targets = []
      variants.each do |v|
        target = v.dig(:source, :target)
        if target == "ruby" or target.nil?
          primary = v
        else
          targets << v[:source]
        end
      end
      if primary.nil?
        spec = variants.first.clone
        spec[:source] = {}
        primary = spec
      end
      [name, primary.merge(targets: targets)]
    end.to_h
  end

  def groups(spec, dep_cache)
    {groups: dep_cache.fetch(spec.name).groups}
  end

  PLATFORM_MAPPING = {}

  {
    "ruby" => [{engine: "ruby"}, {engine:"rbx"}, {engine:"maglev"}],
    "mri" => [{engine: "ruby"}, {engine: "maglev"}],
    "rbx" => [{engine: "rbx"}],
    "jruby" => [{engine: "jruby"}],
    "mswin" => [{engine: "mswin"}],
    "mswin64" => [{engine: "mswin64"}],
    "mingw" => [{engine: "mingw"}],
    "truffleruby" => [{engine: "ruby"}],
    "x64_mingw" => [{engine: "mingw"}],
  }.each do |name, list|
    PLATFORM_MAPPING[name] = list
    %w(1.8 1.9 2.0 2.1 2.2 2.3 2.4 2.5 2.6).each do |version|
      PLATFORM_MAPPING["#{name}_#{version.sub(/[.]/,'')}"] = list.map do |platform|
        platform.merge(:version => version)
      end
    end
  end

  def platforms(spec, dep_cache)
    # c.f. Bundler::CurrentRuby
    platforms = dep_cache.fetch(spec.name).platforms.map do |platform_name|
      PLATFORM_MAPPING[platform_name.to_s]
    end.flatten

    {platforms: platforms}
  end

  def convert_spec(spec, dep_cache)
    [ platforms(spec, dep_cache),
      groups(spec, dep_cache),
      Source.new(spec, fetcher).convert,
    ].inject(&:merge)
  rescue => ex
    warn "Skipping #{spec.name}: #{ex}"
    puts ex.backtrace
    {}
  end

  def build_depcache(lock)
    definition = Bundler::Definition.build(options[:gemfile], options[:lockfile], false)
    dep_cache = {}

    definition.dependencies.each do |dep|
      dep_cache[dep.name] = dep
    end

    lock.specs.each do |spec|
      dep_cache[spec.name] ||= Dependency.new(spec.name, nil, {})
    end

    begin
      changed = false
      lock.specs.each do |spec|
        as_dep = dep_cache.fetch(spec.name)

        spec.dependencies.each do |dep|
          cached = dep_cache.fetch(dep.name) do |name|
            if name != "bundler"
              raise KeyError, "Gem dependency '#{name}' not specified in #{options[:lockfile]}"
            end
            dep_cache[name] = Dependency.new(name, lock.bundler_version, {})
          end

          if !((as_dep.groups - cached.groups) - [:default]).empty? or !(as_dep.platforms - cached.platforms).empty?
            changed = true
            dep_cache[cached.name] = (Dependency.new(cached.name, nil, {
              "group" => as_dep.groups | cached.groups,
              "platforms" => as_dep.platforms | cached.platforms
            }))

            cc = dep_cache[cached.name]
          end
        end
      end
    end while changed

    return dep_cache
  end

  def parse_lockfile
    Bundler::LockfileParser.new(File.read(options[:lockfile]))
  end

  def self.sh(*args, &block)
    out, status = Open3.capture2(*args)
    unless block_given? ? block.call(status, out) : status.success?
      puts "$ #{args.join(' ')}" if $VERBOSE
      puts out if $VERBOSE
      fail "command execution failed: #{status}"
    end
    out
  end
end
