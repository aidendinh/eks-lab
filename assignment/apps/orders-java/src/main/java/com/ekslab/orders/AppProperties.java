package com.ekslab.orders;

import java.util.Arrays;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "app")
public class AppProperties {

    private String serviceName = "orders";
    private String clusterName = "eks-workload";
    private String dataDir = "/data";
    private String downstreamUrls = "";
    private String otlpTracesEndpoint = "";
    private final Collector collector = new Collector();

    public static class Collector {
        private String url = "";
        private String nodeUrl = "";
        private String applicationName = "orders";

        public String getUrl() {
            return url;
        }

        public void setUrl(String url) {
            this.url = url;
        }

        public String getNodeUrl() {
            return nodeUrl;
        }

        public void setNodeUrl(String nodeUrl) {
            this.nodeUrl = nodeUrl;
        }

        public String getApplicationName() {
            return applicationName;
        }

        public void setApplicationName(String applicationName) {
            this.applicationName = applicationName;
        }
    }

    /** Comma-separated in the environment, matching the Python service's DOWNSTREAM_URLS. */
    public List<String> downstreamUrlList() {
        if (downstreamUrls == null || downstreamUrls.isBlank()) {
            return List.of();
        }
        return Arrays.stream(downstreamUrls.split(","))
                .map(String::trim)
                .filter(value -> !value.isEmpty())
                .toList();
    }

    public String getServiceName() {
        return serviceName;
    }

    public void setServiceName(String serviceName) {
        this.serviceName = serviceName;
    }

    public String getClusterName() {
        return clusterName;
    }

    public void setClusterName(String clusterName) {
        this.clusterName = clusterName;
    }

    public String getDataDir() {
        return dataDir;
    }

    public void setDataDir(String dataDir) {
        this.dataDir = dataDir;
    }

    public String getDownstreamUrls() {
        return downstreamUrls;
    }

    public void setDownstreamUrls(String downstreamUrls) {
        this.downstreamUrls = downstreamUrls;
    }

    public String getOtlpTracesEndpoint() {
        return otlpTracesEndpoint;
    }

    public void setOtlpTracesEndpoint(String otlpTracesEndpoint) {
        this.otlpTracesEndpoint = otlpTracesEndpoint;
    }

    public Collector getCollector() {
        return collector;
    }
}
