module LogStash
  module Outputs
    module ElasticSearchPoolMixin
      module LicenseChecker

        # This mixin is used to externalize the license checking behaviour of the LogStash::Outputs::ElasticSearch::HttpClient::Pool class.

        # Perform a license check
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
      end
    end
  end
end
