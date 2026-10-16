package com.airsim.phonecontrol;

import java.net.URI;
import java.util.Map;
import java.util.regex.Pattern;

public final class ReleaseAssetSelector {
    private static final Pattern PACKAGE_NAME = Pattern.compile(
            "airsim-avf-agent_[0-9][0-9A-Za-z.+:~_-]{0,127}_arm64\\.deb");

    public record Selection(String packageName, String packageURL, String signatureURL) {}

    private ReleaseAssetSelector() {}

    public static Selection select(Map<String, String> assets) {
        String packageName = null;
        String packageURL = null;
        for (Map.Entry<String, String> asset : assets.entrySet()) {
            if (!PACKAGE_NAME.matcher(asset.getKey()).matches()) continue;
            if (packageName != null) {
                throw new IllegalArgumentException("Release contains multiple AirSIM arm64 Debian packages");
            }
            packageName = asset.getKey();
            packageURL = requireHTTPS(asset.getValue());
        }
        if (packageName == null) {
            throw new IllegalArgumentException("Release has no AirSIM arm64 Debian package");
        }
        String signatureURL = assets.get(packageName + ".sig");
        if (signatureURL == null) {
            throw new IllegalArgumentException("Release is missing the Debian package signature");
        }
        return new Selection(packageName, packageURL, requireHTTPS(signatureURL));
    }

    private static String requireHTTPS(String value) {
        try {
            URI uri = URI.create(value);
            if (!"https".equals(uri.getScheme()) || uri.getHost() == null) {
                throw new IllegalArgumentException("Release assets must use HTTPS");
            }
            return uri.toString();
        } catch (RuntimeException error) {
            throw new IllegalArgumentException("Invalid release asset address", error);
        }
    }
}
