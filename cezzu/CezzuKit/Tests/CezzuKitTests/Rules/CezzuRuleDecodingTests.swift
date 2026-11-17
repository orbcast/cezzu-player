import Foundation
import Testing
@testable import CezzuKit

@Suite("CezzuRule decoding")
struct CezzuRuleDecodingTests {

    /// Full feature set rule (api 6, anti-crawler enabled).
    @Test("full feature rule decodes")
    func decodeFullFeature() throws {
        let json = """
        {
            "api": "6",
            "type": "anime",
            "name": "demo-full",
            "version": "2.0",
            "muliSources": true,
            "useWebview": true,
            "useNativePlayer": true,
            "usePost": false,
            "useLegacyParser": true,
            "adBlocker": false,
            "userAgent": "",
            "baseURL": "https://example.invalid/",
            "searchURL": "https://example.invalid/search.html?wd=@keyword",
            "searchList": "//div[@class='vod-detail style-detail cor4 search-list']",
            "searchName": "//div/div[2]/a/h3",
            "searchResult": "//div/div[2]/a",
            "chapterRoads": "//ul[@class='anthology-list-play size']",
            "chapterResult": "//li/a",
            "referer": "",
            "antiCrawlerConfig": {
                "enabled": true,
                "captchaType": 1,
                "captchaImage": "//img[@class='ds-verify-img']",
                "captchaInput": "//div[4]/div[2]/div/div/input",
                "captchaButton": "//div[4]/div[2]/button"
            }
        }
        """
        let rule = try JSONDecoder().decode(CezzuRule.self, from: Data(json.utf8))
        #expect(rule.api == "6")
        #expect(rule.name == "demo-full")
        #expect(rule.version == "2.0")
        #expect(rule.muliSources == true)
        #expect(rule.useNativePlayer == true)
        #expect(rule.usePost == false)
        #expect(rule.useLegacyParser == true)
        #expect(rule.baseURL == "https://example.invalid/")
        #expect(rule.searchURL.contains("@keyword"))
        #expect(rule.antiCrawlerConfig != nil)
        #expect(rule.antiCrawlerConfig?.enabled == true)
        #expect(rule.antiCrawlerConfig?.captchaType == .imageCaptcha)
    }

    /// Minimal api-1 rule — only mandatory fields.
    @Test("minimal rule decodes with defaults")
    func decodeMinimal() throws {
        let json = """
        {
            "api": "1",
            "type": "anime",
            "name": "demo-minimal",
            "version": "1.5",
            "muliSources": true,
            "useWebview": true,
            "useNativePlayer": true,
            "userAgent": "",
            "baseURL": "https://example.invalid/",
            "searchURL": "https://example.invalid/search?query=@keyword",
            "searchList": "//div[2]/div/section/div/div/div/div",
            "searchName": "//div/div[2]/h5/a",
            "searchResult": "//div/div[2]/h5/a",
            "chapterRoads": "//div[2]/div/section/div/div[2]/div[2]/div[2]/div",
            "chapterResult": "//ul/li/a"
        }
        """
        let rule = try JSONDecoder().decode(CezzuRule.self, from: Data(json.utf8))
        #expect(rule.usePost == false)             // default
        #expect(rule.useLegacyParser == false)     // default
        #expect(rule.adBlocker == false)           // default
        #expect(rule.referer == "")                // default
        #expect(rule.antiCrawlerConfig == nil)     // default
    }

    /// api 8 只写了 `enabled`，其余 captcha 字段整体省略。
    @Test("antiCrawlerConfig with only enabled decodes")
    func decodeAntiCrawlerConfigWithOnlyEnabled() throws {
        let json = """
        {
            "api": "8",
            "type": "anime",
            "name": "demo-captcha",
            "version": "1.2",
            "muliSources": true,
            "useWebview": true,
            "useNativePlayer": true,
            "userAgent": "",
            "baseURL": "https://example.invalid/",
            "searchURL": "https://example.invalid/Index/search.html?searchText=@keyword",
            "searchList": "//section[@id='some_drama']/div",
            "searchName": "//p",
            "searchResult": "//a",
            "chapterRoads": "//section[@class='anthology'][1]/div",
            "chapterResult": "//a",
            "antiCrawlerConfig": {
                "enabled": false
            }
        }
        """
        let rule = try JSONDecoder().decode(CezzuRule.self, from: Data(json.utf8))
        #expect(rule.antiCrawlerConfig?.enabled == false)
        #expect(rule.antiCrawlerConfig?.captchaImage == "")
        #expect(rule.antiCrawlerConfig?.captchaInput == "")
        #expect(rule.antiCrawlerConfig?.captchaButton == "")
    }

    @Test("muliSources is required (cezzu-rule schema)")
    func muliSourcesIsRequired() throws {
        // 缺少 muliSources 字段时必须解码失败
        let json = """
        {
            "api": "1",
            "type": "anime",
            "name": "broken",
            "version": "1.0",
            "useWebview": true,
            "useNativePlayer": true,
            "userAgent": "",
            "baseURL": "https://example.com/",
            "searchURL": "https://example.com/?q=@keyword",
            "searchList": "//a",
            "searchName": "//a",
            "searchResult": "//a",
            "chapterRoads": "//ul",
            "chapterResult": "//li/a"
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CezzuRule.self, from: Data(json.utf8))
        }
    }

    @Test("api and version are strings, not ints")
    func apiAndVersionAreStrings() throws {
        let json = """
        {
            "api": "5",
            "type": "anime",
            "name": "stringy",
            "version": "1.2",
            "muliSources": true,
            "useWebview": true,
            "useNativePlayer": true,
            "userAgent": "",
            "baseURL": "https://example.com/",
            "searchURL": "https://example.com/?q=@keyword",
            "searchList": "//a",
            "searchName": "//a",
            "searchResult": "//a",
            "chapterRoads": "//ul",
            "chapterResult": "//li/a"
        }
        """
        let rule = try JSONDecoder().decode(CezzuRule.self, from: Data(json.utf8))
        #expect(rule.api == "5")
        #expect(rule.version == "1.2")
    }

    @Test("@keyword substitution is URL-encoded")
    func resolvedSearchURL() throws {
        let rule = CezzuRule(
            api: "1",
            type: "anime",
            name: "demo",
            version: "1.0",
            muliSources: false,
            useWebview: true,
            useNativePlayer: true,
            userAgent: "",
            baseURL: "https://example.com/",
            searchURL: "https://example.com/s?wd=@keyword",
            searchList: "//a",
            searchName: "//a",
            searchResult: "//a",
            chapterRoads: "//ul",
            chapterResult: "//li/a"
        )
        let url = rule.resolvedSearchURL(for: "孤独摇滚")
        #expect(url != nil)
        // URL-encoded "孤独摇滚"
        #expect(url?.absoluteString.contains("%E5%AD%A4%E7%8B%AC%E6%91%87%E6%BB%9A") == true)
    }

    /// API 9 的两个可选字段：缺失时是空串，不能让既有的 84 条规则解不出来。
    @Test("api 9 fields default to empty when absent")
    func apiNineFieldsDefaultEmpty() throws {
        let rule = try JSONDecoder().decode(
            CezzuRule.self, from: Data(CezzuRuleFixtures.minimal.utf8)
        )
        #expect(rule.cookies.isEmpty)
        #expect(rule.videoURLPattern.isEmpty)
    }

    @Test("decodes cookies and videoURLPattern when present")
    func decodesApiNineFields() throws {
        let json = CezzuRuleFixtures.minimal.replacingOccurrences(
            of: #""chapterResult": "//li/a""#,
            with: #""chapterResult": "//li/a", "cookies": "quality=1080", "videoURLPattern": "(?<v>https.+\\.m3u8)""#
        )
        let rule = try JSONDecoder().decode(CezzuRule.self, from: Data(json.utf8))
        #expect(rule.cookies == "quality=1080")
        #expect(rule.videoURLPattern == #"(?<v>https.+\.m3u8)"#)
    }

}
