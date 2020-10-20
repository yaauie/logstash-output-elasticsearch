# encoding: utf-8
require "logstash/namespace"
require "logstash/environment"
require "logstash/outputs/base"
require "logstash/json"
require "concurrent"
require "stud/buffer"
require "socket" # for Socket.gethostname
require "thread" # for safe queueing
require "uri" # for escaping user input
require "forwardable"

# .Compatibility Note
# [NOTE]
# ================================================================================
# Starting with Elasticsearch 5.3, there's an {ref}modules-http.html[HTTP setting]
# called `http.content_type.required`. If this option is set to `true`, and you
# are using Logstash 2.4 through 5.2, you need to update the Elasticsearch output
# plugin to version 6.2.5 or higher.
#
# ================================================================================
#
# This plugin is the recommended method of storing logs in Elasticsearch.
# If you plan on using the Kibana web interface, you'll want to use this output.
#
# This output only speaks the HTTP protocol. HTTP is the preferred protocol for interacting with Elasticsearch as of Logstash 2.0.
# We strongly encourage the use of HTTP over the node protocol for a number of reasons. HTTP is only marginally slower,
# yet far easier to administer and work with. When using the HTTP protocol one may upgrade Elasticsearch versions without having
# to upgrade Logstash in lock-step.
#
# You can learn more about Elasticsearch at <https://www.elastic.co/products/elasticsearch>
#
# ==== Template management for Elasticsearch 5.x
# Index template for this version (Logstash 5.0) has been changed to reflect Elasticsearch's mapping changes in version 5.0.
# Most importantly, the subfield for string multi-fields has changed from `.raw` to `.keyword` to match ES default
# behavior.
#
# ** Users installing ES 5.x and LS 5.x **
# This change will not affect you and you will continue to use the ES defaults.
#
# ** Users upgrading from LS 2.x to LS 5.x with ES 5.x **
# LS will not force upgrade the template, if `logstash` template already exists. This means you will still use
# `.raw` for sub-fields coming from 2.x. If you choose to use the new template, you will have to reindex your data after
# the new template is installed.
#
# ==== Retry Policy
#
# The retry policy has changed significantly in the 2.2.0 release.
# This plugin uses the Elasticsearch bulk API to optimize its imports into Elasticsearch. These requests may experience
# either partial or total failures.
#
# The following errors are retried infinitely:
#
# - Network errors (inability to connect)
# - 429 (Too many requests) and
# - 503 (Service unavailable) errors
#
# NOTE: 409 exceptions are no longer retried. Please set a higher `retry_on_conflict` value if you experience 409 exceptions.
# It is more performant for Elasticsearch to retry these exceptions than this plugin.
#
# ==== Batch Sizes ====
# This plugin attempts to send batches of events as a single request. However, if
# a request exceeds 20MB we will break it up until multiple batch requests. If a single document exceeds 20MB it will be sent as a single request.
#
# ==== DNS Caching
#
# This plugin uses the JVM to lookup DNS entries and is subject to the value of https://docs.oracle.com/javase/7/docs/technotes/guides/net/properties.html[networkaddress.cache.ttl],
# a global setting for the JVM.
#
# As an example, to set your DNS TTL to 1 second you would set
# the `LS_JAVA_OPTS` environment variable to `-Dnetworkaddress.cache.ttl=1`.
#
# Keep in mind that a connection with keepalive enabled will
# not reevaluate its DNS value while the keepalive is in effect.
#
# ==== HTTP Compression
#
# This plugin supports request and response compression. Response compression is enabled by default and 
# for Elasticsearch versions 5.0 and later, the user doesn't have to set any configs in Elasticsearch for 
# it to send back compressed response. For versions before 5.0, `http.compression` must be set to `true` in 
# Elasticsearch[https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-http.html#modules-http] to take advantage of response compression when using this plugin
#
# For requests compression, regardless of the Elasticsearch version, users have to enable `http_compression` 
# setting in their Logstash config file.
#
class LogStash::Outputs::ElasticSearch < LogStash::Outputs::Base
  declare_threadsafe!

  require "logstash/outputs/elasticsearch/http_client"
  require "logstash/outputs/elasticsearch/http_client_builder"
  require "logstash/outputs/elasticsearch/elasticsearch_configs"
  require "logstash/outputs/elasticsearch/shared_configs"
  require "logstash/outputs/elasticsearch/common"
  require "logstash/outputs/elasticsearch/ilm"

  require 'logstash/plugin_mixins/ecs_compatibility_support'

  # Elasticsearch output only configs
  include(LogStash::Outputs::ElasticSearch::ElasticsearchConfigs)

  # Shared configs with data_streams output
  include(LogStash::Outputs::ElasticSearch::SharedConfigs)

  # Protocol agnostic methods
  include(LogStash::Outputs::ElasticSearch::Common)

  # Methods for ILM support
  include(LogStash::Outputs::ElasticSearch::Ilm)

  # ecs_compatibility option, provided by Logstash core or the support adapter.
  include(LogStash::PluginMixins::ECSCompatibilitySupport)

  config_name "elasticsearch"

  def initialize(*params)
    super
    setup_ecs_compatibility_related_defaults
  end

  def setup_ecs_compatibility_related_defaults
    case ecs_compatibility
    when :disabled
      @default_index = "logstash-%{+yyyy.MM.dd}"
      @default_ilm_rollover_alias = "logstash"
      @default_template_name = 'logstash'
    when :v1
      @default_index = "ecs-logstash-%{+yyyy.MM.dd}"
      @default_ilm_rollover_alias = "ecs-logstash"
      @default_template_name = 'ecs-logstash'
    else
      fail("unsupported ECS Compatibility `#{ecs_compatibility}`")
    end

    @index ||= default_index
    @ilm_rollover_alias ||= default_ilm_rollover_alias
    @template_name ||= default_template_name
  end

  attr_reader :default_index
  attr_reader :default_ilm_rollover_alias
  attr_reader :default_template_name

  # @override to handle proxy => '' as if none was set
  def config_init(params)
    proxy = params['proxy']
    if proxy.is_a?(String)
      # environment variables references aren't yet resolved
      proxy = deep_replace(proxy)
      if proxy.empty?
        params.delete('proxy')
        @proxy = ''
      else
        params['proxy'] = proxy # do not do resolving again
      end
    end
    super(params)
  end

  def build_client
    # the following 3 options validation & setup methods are called inside build_client
    # because they must be executed prior to building the client and logstash
    # monitoring and management rely on directly calling build_client
    # see https://github.com/logstash-plugins/logstash-output-elasticsearch/pull/934#pullrequestreview-396203307
    validate_authentication
    fill_hosts_from_cloud_id
    setup_hosts

    params["metric"] = metric
    if @proxy.eql?('')
      @logger.warn "Supplied proxy setting (proxy => '') has no effect"
    end
    @client ||= ::LogStash::Outputs::ElasticSearch::HttpClientBuilder.build(@logger, @hosts, params)
  end

  def close
    @stopping.make_true if @stopping
    stop_template_installer
    @client.close if @client
  end

  def self.oss?
    LogStash::OSS
  end

  @@plugins = Gem::Specification.find_all{|spec| spec.name =~ /logstash-output-elasticsearch-/ }

  @@plugins.each do |plugin|
    name = plugin.name.split('-')[-1]
    require "logstash/outputs/elasticsearch/#{name}"
  end

end
