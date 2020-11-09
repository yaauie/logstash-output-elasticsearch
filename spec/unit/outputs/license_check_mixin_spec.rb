require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/elasticsearch/http_client"

describe LogStash::Outputs::ElasticSearchPoolMixin::LicenseChecker do

  # Note that the actual license checking logic is spec'ed in pool_spec.rb

  context "LicenseChecker mixin API required by Pool class" do
    subject { described_class }

    it "defines the license_check! methods" do
      expect(subject.instance_methods).to include(:license_check!)
    end
  end

  context "Pool class API required by the LicenseChecker mixin" do
    subject { LogStash::Outputs::ElasticSearch::HttpClient::Pool }

    it "contains the get_license method" do
      expect(LogStash::Outputs::ElasticSearch::HttpClient::Pool.instance_methods).to include(:get_license)
    end

    it "contains the logger method" do
      expect(LogStash::Outputs::ElasticSearch::HttpClient::Pool.instance_methods).to include(:logger)
    end
  end
end

