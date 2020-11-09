module LogStash
  module Outputs
    module ElasticSearchPoolMixin
      module LicenseChecker

        # This mixin is used to externalize the license checking behaviour of the LogStash::Outputs::ElasticSearch::HttpClient::Pool class.
        # This mixin uses the following Pool methods: get_license, logger. Make sure these are defined in the license_check_mixin_spec.rb.

        # Perform a license check
        # The license_check! methods is the method called from LogStash::Outputs::ElasticSearch::HttpClient::Pool#healthcheck!
        # @param url [LogStash::Util::SafeURI]
        # @param meta [Hash]
        def license_check!(url, meta)
          if oss? || valid_es_license?(url)
            meta[:state] = :alive
          else
            # As this version is to be shipped with Logstash 7.x we won't mark the connection as unlicensed
            #
            #  logger.error("Cannot connect to the Elasticsearch cluster configured in the Elasticsearch output. Logstash requires the default distribution of Elasticsearch. Please update to the default distribution of Elasticsearch for full access to all free features, or switch to the OSS distribution of Logstash.", :url => url.sanitized.to_s)
            #  meta[:state] = :unlicensed
            #
            # Instead we'll log a deprecation warning and mark it as alive:
            #
            log_license_deprecation_warn(url)
            meta[:state] = :alive
          end
        end

        def oss?
          LogStash::OSS
        end

        def valid_es_license?(url)
          license = get_license(url)
          license.fetch("license", {}).fetch("status", nil) == "active"
        rescue => e
          false
        end

        def log_license_deprecation_warn(url)
          logger.warn("DEPRECATION WARNING: Connecting to an OSS distribution of Elasticsearch using the default distribution of Logstash will stop working in Logstash 8.0.0. Please upgrade to the default distribution of Elasticsearch, or use the OSS distribution of Logstash", :url => url.sanitized.to_s)
        end
      end
    end
  end
end
