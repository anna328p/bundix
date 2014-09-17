require 'bundix/prefetcher'
require 'yaml'

class Bundix::Prefetcher::Cache
  class << self
    def read(pathname)
      new(YAML.load(pathname.read))
    end
  end

  def initialize(content = {})
    @cache = content
  end

  def has?(source)
    !!get(source)
  end

  def get(source)
    source.components.inject(@cache) do |hash, component|
      hash[component] || break
    end
  end

  def set(source)
    components = source.components.dup
    last = components.pop
    
    hash = components.inject(@cache) do |acc, component|
      acc[component] ||= Hash.new
    end

    hash[last] = source.sha256
  end

  # @param [Pathname] path
  def write(path)
    path.open('w') { |file| file.write(YAML.dump(@cache)) }
  end

  protected

  def identifier(spec)
    source = spec.source
    components = case source
    when Bundler::Source::Git then [source.uri, source.revision]
    when Bundler::Source::Rubygems then
      [File.join(source.remotes.first.to_s, 'downloads', "#{spec.name}-#{spec.version}.gem")]
    end

    components.join('#')
  end
end
