package com.brentvatne.exoplayer

import android.net.Uri
import androidx.media3.common.util.Util
import androidx.media3.datasource.AssetDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import com.facebook.react.bridge.ReactContext
import com.facebook.react.modules.network.CookieJarContainer
import com.facebook.react.modules.network.ForwardingCookieHandler
import com.facebook.react.modules.network.OkHttpClientProvider
import okhttp3.Call
import okhttp3.JavaNetCookieJar

object DataSourceUtil {
    private var defaultDataSourceFactory: DataSource.Factory? = null
    private var defaultHttpDataSourceFactory: HttpDataSource.Factory? = null
    private var userAgent: String? = null

    private fun getUserAgent(context: ReactContext): String {
        if (userAgent == null) {
            userAgent = Util.getUserAgent(context, context.packageName)
        }
        return userAgent as String
    }

    @JvmStatic
    fun getDefaultDataSourceFactory(context: ReactContext, bandwidthMeter: DefaultBandwidthMeter?, requestHeaders: Map<String, String>?): DataSource.Factory {
        if (defaultDataSourceFactory == null || !requestHeaders.isNullOrEmpty()) {
            defaultDataSourceFactory = buildDataSourceFactory(context, bandwidthMeter, requestHeaders)
        }
        return defaultDataSourceFactory as DataSource.Factory
    }

    @JvmStatic
    fun getDefaultHttpDataSourceFactory(
        context: ReactContext,
        bandwidthMeter: DefaultBandwidthMeter?,
        requestHeaders: Map<String, String>?
    ): HttpDataSource.Factory {
        if (defaultHttpDataSourceFactory == null || !requestHeaders.isNullOrEmpty()) {
            defaultHttpDataSourceFactory = buildHttpDataSourceFactory(context, bandwidthMeter, requestHeaders)
        }
        return defaultHttpDataSourceFactory as HttpDataSource.Factory
    }

    private fun buildDataSourceFactory(
        context: ReactContext,
        bandwidthMeter: DefaultBandwidthMeter?,
        requestHeaders: Map<String, String>?
    ): DataSource.Factory = DefaultDataSource.Factory(context, buildHttpDataSourceFactory(context, bandwidthMeter, requestHeaders))

    private fun buildHttpDataSourceFactory(
        context: ReactContext,
        bandwidthMeter: DefaultBandwidthMeter?,
        requestHeaders: Map<String, String>?
    ): HttpDataSource.Factory {
        val client = OkHttpClientProvider.getOkHttpClient()
        val container = client.cookieJar as CookieJarContainer
        val handler = ForwardingCookieHandler(context)
        container.setCookieJar(JavaNetCookieJar(handler))
        val okHttpDataSourceFactory = OkHttpDataSource.Factory(client as Call.Factory)
            .setTransferListener(bandwidthMeter)

        if (requestHeaders != null) {
            okHttpDataSourceFactory.setDefaultRequestProperties(requestHeaders)
            if (!requestHeaders.containsKey("User-Agent")) {
                okHttpDataSourceFactory.setUserAgent(getUserAgent(context))
            }
        } else {
            okHttpDataSourceFactory.setUserAgent(getUserAgent(context))
        }

        return okHttpDataSourceFactory
    }

    /**
     * Appends a raw `key=value` query token to every request made through [factory].
     *
     * HLS/DASH child URIs (sub-playlists, segments, keys) are resolved relatively to the
     * manifest, and RFC 3986 relative resolution drops the base query. CDNs that validate a
     * token on every request therefore need it re-applied per request, which is what
     * [ResolvingDataSource] is for.
     */
    @JvmStatic
    fun withQueryToken(factory: DataSource.Factory, token: String?): DataSource.Factory {
        val normalized = token?.trimStart('?', '&')?.trim().orEmpty()
        if (normalized.isEmpty()) return factory
        return ResolvingDataSource.Factory(factory) { dataSpec ->
            dataSpec.withUri(appendQueryToken(dataSpec.uri, normalized))
        }
    }

    private fun appendQueryToken(uri: Uri, token: String): Uri {
        val query = uri.encodedQuery
        // already carries this token (e.g. the manifest URL built on the JS side)
        if (query != null && query.contains(token)) return uri
        val merged = if (query.isNullOrEmpty()) token else "$query&$token"
        return uri.buildUpon().encodedQuery(merged).build()
    }

    @JvmStatic
    fun buildAssetDataSourceFactory(context: ReactContext?, srcUri: Uri?): DataSource.Factory {
        val dataSpec = DataSpec(srcUri!!)
        val rawResourceDataSource = AssetDataSource(context!!)
        rawResourceDataSource.open(dataSpec)
        return DataSource.Factory { rawResourceDataSource }
    }
}
