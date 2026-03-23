require 'sinatra'
require 'google_search_results'
require 'down'
require 'fastimage'
require 'json'
require 'base64'
require 'httparty'
require 'nokogiri'
require 'time'
require 'uri'
require 'timeout'

# --- CONFIGURATION ---
GEMINI_API_KEY     = ENV['GEMINI_API_KEY']
SERPAPI_KEY        = ENV['SERPAPI_KEY']
EAN_SEARCH_TOKEN   = ENV['EAN_SEARCH_TOKEN']
ZENROWS_API_KEY    = ENV['ZENROWS_API_KEY']

BAD_URL_PATTERNS = %w[
  rezept recipe kuchen torta blog forum pinterest wiki tiktok facebook instagram
  .xml .xml.gz .pdf .zip .gz .csv sitemap
  scribd academia researchgate tamu.edu github trinket joybuy momogo
].freeze

# ADDED: diagnostic_log and text_scraped_length to the allowed keys
ALLOWED_KEYS = %w[
  diagnostic_log text_scraped_length brand product_name net_weight ingredients 
  allergens may_contain nutri_scope energy fat saturates carbs sugars protein 
  fiber salt organic_id sources_summary dietary_info format occasion
].freeze

class MasterDataHunter
  include HTTParty

  def initialize
    @headers = { 'Content-Type' => 'application/json' }

    # 1. Market Language Logic
    @country_langs = {
      "DE" => "German", "AT" => "German", "CH" => "German",
      "UK" => "English", "GB" => "English", "FR" => "French",
      "IT" => "Italian", "ES" => "Spanish", "NL" => "Dutch",
      "DK" => "Danish", "SE" => "Swedish", "NO" => "Norwegian",
      "PL" => "Polish", "PT" => "Portuguese", "FI" => "Finnish",
      "BE" => "German, French, AND Dutch (Must provide all 3)"
    }

    # 2. Google HL Codes
    @hl_codes = {
      "DE" => "de", "AT" => "de", "CH" => "de", "UK" => "en", "GB" => "en",
      "FR" => "fr", "IT" => "it", "ES" => "es", "NL" => "nl", "BE" => "nl",
      "DK" => "da", "SE" => "sv", "NO" => "no", "PL" => "pl", "PT" => "pt", "FI" => "fi"
    }

    # 3. Localized Deep Search Terms
    @local_search_terms = {
      "FR" => "ingrédients nutrition", "IT" => "ingredienti nutrizionali", "ES" => "ingredientes nutrición",
      "NL" => "ingrediënten voedingswaarde", "DK" => "ingredienser næringsindhold", "SE" => "ingredienser näringsvärde",
      "NO" => "ingredienser næringsinnhold", "FI" => "ainesosat ravintosisältö", "PL" => "składniki wartości odżywcze",
      "DE" => "zutaten nährwerte", "AT" => "zutaten nährwerte", "CH" => "zutaten nährwerte",
      "BE" => "ingrédients ingrediënten", "UK" => "ingredients nutrition", "PT" => "ingredientes nutrição"
    }

    # 4. Country Names for Image Hunting
    @country_names = {
      "DE" => "Deutschland Germany", "AT" => "Österreich Austria", "CH" => "Schweiz Switzerland",
      "UK" => "UK United Kingdom",   "GB" => "UK United Kingdom", "FR" => "France",
      "IT" => "Italia Italy", "ES" => "España Spain", "PL" => "Polska Poland",
      "DK" => "Danmark Denmark", "NL" => "Nederland Netherlands", "BE" => "Belgique België Belgium",
      "SE" => "Sverige Sweden", "NO" => "Norge Norway", "PT" => "Portugal", "FI" => "Suomi Finland"
    }

    # 5. Trusted Retailers
    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com",
      "UK" => "site:ocado.com OR site:waitrose.com OR site:asda.com OR site:tesco.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:motatos.de",
      "AT" => "site:billa.at OR site:spar.at OR site:gurkerl.at OR site:motatos.at",
      "DK" => "site:nemlig.com OR site:matsmart.dk OR site:rema1000.dk",
      "IT" => "site:carrefour.it OR site:conad.it OR site:coop.it",
      "ES" => "site:carrefour.es OR site:mercadona.es OR site:dia.es",
      "SE" => "site:ica.se OR site:coop.se OR site:willys.se",
      "NO" => "site:oda.com OR site:meny.no OR site:holdbart.no",
      "FI" => "site:k-ruoka.fi OR site:s-kaupat.fi OR site:matsmart.fi",
      "PL" => "site:carrefour.pl OR site:auchan.pl OR site:frisco.pl"
    }

    global_sites = "site:billigkaffee.eu OR site:fivestartrading-holland.eu"
    @goldmine_sites.each { |market, sites| @goldmine_sites[market] = "#{sites} OR #{global_sites}" }
    @goldmine_sites.default = global_sites
  end

  def process_product(gtin, market)
    return { found: false, status: "Missing GEMINI_API_KEY" } if GEMINI_API_KEY.nil? || GEMINI_API_KEY.empty?

    confirmed_sources = []
    is_deep_search = false

    # --- STEP 1: OFFICIAL REGISTRY ---
    official_data = fetch_official_ean_data(gtin)
    registry_name = official_data ? official_data['name'] : nil
    if official_data
      confirmed_sources << { type: "registry", title: "Official Registry", url: "https://www.ean-search.org/?q=#{gtin}" }
    end

    # --- STEP 2: PARALLEL SEARCH ---
    threads = []
    retailer_results = []
    threads << Thread.new { retailer_results = find_retailer_urls(gtin, market) }

    deep_results = []
    threads << Thread.new do
      search_name = registry_name || infer_name_from_ean(gtin, market)
      deep_results = search_name ? find_deep_urls(search_name, market) : find_retailer_urls(gtin, market)
    end

    image_data = nil
    image_thread = Thread.new { image_data = find_best_image(gtin, market, official_data) }

    # Wait for threads
    deadline = Time.now + 25
    image_deadline = Time.now + 18
    image_thread.join([image_deadline - Time.now, 0.5].max) if image_thread.alive?
    threads.each { |t| remaining = deadline - Time.now; t.join(remaining > 0 ? remaining : 0.1) }
    (threads + [image_thread]).each { |t| t.kill if t.alive? }

    all_urls = (retailer_results + deep_results).uniq.first(10)

    # --- STEP 3: SCRAPING ---
    web_data = fetch_parallel_page_data(all_urls)
    web_data[:valid_urls].each { |u| confirmed_sources << { type: "web", title: host_from_url(u), url: u } }

    if image_data
      confirmed_sources << { type: "image", title: "Source Image", url: image_data[:url] }
    end

    if (image_data.nil? || image_data[:base64].nil?) && web_data[:text].strip.empty?
      return empty_result(gtin, market, "No Data Found (Blind)", nil)
    end

    final_name_context = official_data ? official_data : { 'name' => registry_name }
    
    # Image confidence check
    image_confidence_note = nil
    if image_data && web_data[:valid_urls].any?
      image_host = URI.parse(image_data[:url]).host.sub(/^www\./, '') rescue nil
      web_hosts = web_data[:valid_urls].map { |u| URI.parse(u).host.sub(/^www\./, '') rescue nil }.compact
      unless web_hosts.any? { |h| h.include?(image_host.to_s.split('.').first) }
        image_confidence_note = "NOTE: Image source domain does not match web sources. Prefer text data over image data if they conflict."
      end
    end

    # --- STEP 4: AI ANALYSIS ---
    ai_result = analyze_with_gemini(image_data, web_data[:text], final_name_context, gtin, market, image_confidence_note)

    ai_hash = {}
    if ai_result.is_a?(Hash)
      ALLOWED_KEYS.each { |k| ai_hash[k] = ai_result[k] if ai_result.key?(k) }
      ai_hash["error"] = ai_result["error"] if ai_result["error"]
    end

    return empty_result(gtin, market, ai_hash["error"], image_data ? image_data[:url] : nil) if ai_hash["error"]

    # --- STEP 5: FALLBACK ESCALATION ---
    ing_text = ai_hash["ingredients"].to_s.downcase
    missing_phrases = ["keine", "not found", "unavailable", "inconnu", "none", "no disponible", "brak", "non trovato"]
    nutrition_fields = %w[energy fat saturates carbs sugars protein salt]
    is_empty_val = ->(v) { v.to_s.strip.empty? || v.to_s.strip == "-" || v.to_s.downcase.include?("not") }
    nutrition_missing = nutrition_fields.count { |f| is_empty_val.call(ai_hash[f]) }

    if ing_text.length < 10 || missing_phrases.any? { |p| ing_text.include?(p) } || nutrition_missing >= 5
      log("Fallback Escalation triggered for #{gtin}")
      search_name = ai_hash["product_name"] || registry_name || infer_name_from_ean(gtin, market)

      if search_name && search_name.length > 3
        fallback_urls = find_deep_urls(search_name, market)
        if fallback_urls.any?
          fallback_web_data = fetch_parallel_page_data(fallback_urls)
          if fallback_web_data[:text].length > 200
            is_deep_search = true
            combined_text = web_data[:text] + "\n\n=== FALLBACK DATA ===\n" + fallback_web_data[:text]
            fallback_web_data[:valid_urls].each { |u| confirmed_sources << { type: "rescue", title: host_from_url(u), url: u } }

            ai_result2 = analyze_with_gemini(image_data, combined_text, final_name_context, gtin, market, image_confidence_note)
            if ai_result2.is_a?(Hash) && !ai_result2["error"]
              ALLOWED_KEYS.each do |k|
                next unless ai_result2.key?(k)
                new_val, old_val = ai_result2[k].to_s.strip, ai_hash[k].to_s.strip
                ai_hash[k] = ai_result2[k] if is_empty_val.call(old_val) || (!is_empty_val.call(new_val) && new_val.length > old_val.length)
              end
            end
            web_data[:text] = combined_text # Update text length for logging
          end
        end
      end
    end

    origin_country = official_data ? official_data['issuingCountry'] : nil
    display_image = if image_data && image_data[:base64] && image_data[:mime]
                      "data:#{image_data[:mime]};base64,#{image_data[:base64]}"
                    else
                      image_data ? image_data[:url] : nil
                    end

    has_registry = !!official_data
    has_image = image_data && image_data[:base64]
    has_web = web_data[:valid_urls].any? && web_data[:text].length > 200

    computed_status = if is_deep_search then "Found (Deep Search)"
                      elsif has_registry && has_web && has_image then "Found (Registry+Web+Image)"
                      elsif has_web && has_image then "Found (Web+Image)"
                      elsif has_web then "Found (Web)"
                      elsif has_image && has_registry then "Found (Registry+Image)"
                      elsif has_image then "Found (Image)"
                      elsif has_registry then "Registry Only"
                      else "Blind"
                      end

    {
      found: true,
      gtin: gtin,
      status: computed_status,
      market: market,
      image_url: display_image,
      issuing_country: origin_country,
      defined_sources: confirmed_sources.uniq { |s| s[:url] },
      # INJECTING DIAGNOSTICS FOR THE UI
      diagnostic_log: ai_hash["diagnostic_log"] || "No AI thought process returned.",
      text_scraped_length: web_data[:text].length
    }.merge(ai_hash)
  end

  private

  def log(msg)
    STDERR.puts("[#{Time.now.utc.iso8601}] #{msg}")
  end

  def host_from_url(url)
    URI.parse(url).host.sub(/^www\./, '') rescue "Link"
  end

  def mime_from_fastimage(type)
    case type
    when :jpeg, :jpg then "image/jpeg"
    when :png        then "image/png"
    when :webp       then "image/webp"
    when :heic       then "image/heic"
    when :heif       then "image/heif"
    when :avif       then "image/avif"
    when :bmp        then "image/bmp"
    when :gif        then "image/gif"
    else nil
    end
  end

  def is_clean_url?(url)
    return false if url.nil? || url.empty?
    uri_path = URI.parse(url).path.downcase rescue url.downcase
    !BAD_URL_PATTERNS.any? { |p| url.downcase.include?(p) || uri_path.end_with?(p) }
  end

  def infer_name_from_ean(gtin, market)
    return nil if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    begin
      res = Timeout.timeout(15) { GoogleSearch.new(q: "#{gtin}", gl: gl, num: 2, api_key: SERPAPI_KEY).get_hash }
      first_result = (res[:organic_results] || []).first
      return first_result[:title].split(/ [|-] /).first.strip if first_result
    rescue => e
      log("Search API error (name inference): #{e.message}")
    end
    nil
  end

  def find_retailer_urls(gtin, market)
    return [] if SERPAPI_KEY.nil?
    gl = (market == "UK" ? "gb" : market.downcase)
    goldmine = @goldmine_sites[market]
    bans = "-site:openfoodfacts.org"
    return [] unless goldmine

    urls = []
    begin
      res = Timeout.timeout(15) { GoogleSearch.new(q: "#{goldmine} #{gtin} #{bans}", gl: gl, num: 7, api_key: SERPAPI_KEY).get_hash }
      (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
    rescue => e
      log("Search API error (retailers): #{e.message}")
    end
    urls
  end

  def find_deep_urls(name, market)
    return [] if name.nil? || name.length < 3
    gl = (market == "UK" ? "gb" : market.downcase)
    bans = "-site:openfoodfacts.org -site:pinterest.* -site:tiktok.com -site:facebook.com -site:instagram.com"
    clean_name = name.gsub(/[^a-zA-Z0-9\s]/, '').gsub(/\s+/, ' ').strip
    short_name = clean_name.split(' ')[0..3].join(" ")

    goldmine = @goldmine_sites[market]
    local_terms = @local_search_terms[market] || "ingredients nutrition"
    urls = []

    begin
      brand_res = Timeout.timeout(15) { GoogleSearch.new(q: "\"#{short_name}\" ingredients nutrition facts #{bans}", gl: gl, num: 4, api_key: SERPAPI_KEY).get_hash }
      (brand_res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }

      if goldmine
        res = Timeout.timeout(15) { GoogleSearch.new(q: "#{goldmine} #{short_name} #{local_terms} #{bans}", gl: gl, num: 6, api_key: SERPAPI_KEY).get_hash }
        (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end

      if urls.empty?
        res = Timeout.timeout(15) { GoogleSearch.new(q: "#{short_name} #{local_terms} #{bans}", gl: gl, num: 6, api_key: SERPAPI_KEY).get_hash }
        (res[:organic_results] || []).each { |r| urls << r[:link] if is_clean_url?(r[:link]) }
      end
    rescue => e
      log("Search API error (deep links): #{e.message}")
    end
    urls.uniq.first(6)
  end

  def find_best_image(gtin, market, official_data)
    return nil if SERPAPI_KEY.nil? || SERPAPI_KEY.empty?
    gl = (market == "UK" ? "gb" : market.downcase)
    hl = @hl_codes[market] || "en"
    country_name = @country_names[market] || ""

    if official_data && is_good_image_size?(official_data['image'])
      encoded = download_and_encode(official_data['image'], "https://www.ean-search.org/?q=#{gtin}")
      return encoded if encoded
    end

    searches = [
      "site:barcodelookup.com OR site:go-upc.com \"#{gtin}\"",
      "\"#{gtin}\" #{country_name}",
      "\"#{gtin}\""
    ]

    if official_data && official_data['name']
      clean_name = official_data['name'].gsub(/[^a-zA-Z0-9\s]/, '')
      searches << clean_name if clean_name.length > 3
    end

    searches.each_with_index do |query, index|
      begin
        res = Timeout.timeout(10) { GoogleSearch.new(q: query, tbm: "isch", gl: gl, hl: hl, api_key: SERPAPI_KEY).get_hash }
        images = (res[:images_results] || []).first(10)

        images.each do |img|
          url = img[:original]
          next if url.nil? || url.include?("placeholder") || url.include?("pinterest") || url.include?("ebay") || url.include?("openfoodfacts")

          if is_good_image_size?(url)
            encoded = download_and_encode(url, img[:link])
            return encoded if encoded
          end
        end
      rescue => e
        log("IMG SerpAPI fail on query '#{query}': #{e.message}")
      end
    end
    nil
  end

  def is_good_image_size?(url)
    return false if url.nil? || url.empty?
    begin
      size = Timeout.timeout(4) { FastImage.size(url, timeout: 3, http_header: { 'User-Agent' => 'Mozilla/5.0' }) }
      return false unless size
      w, h = size
      w > 300 && (w.to_f / h.to_f).between?(0.3, 2.5)
    rescue
      false
    end
  end

  def download_and_encode(url, source_link)
    tempfile = Down.download(
      url, max_size: 1.5 * 1024 * 1024, open_timeout: 4, read_timeout: 4,
      headers: { "User-Agent" => "Mozilla/5.0", "Referer" => (source_link || "https://www.google.com/") }
    )
    type = FastImage.type(tempfile.path)
    mime = mime_from_fastimage(type)
    return nil unless mime
    base64 = Base64.strict_encode64(File.binread(tempfile.path))
    { url: url, source: source_link, base64: base64, mime: mime }
  rescue => e
    log("IMG download fail url=#{url}: #{e.message}")
    nil
  end

  def fetch_parallel_page_data(urls)
    return { text: "", valid_urls: [] } if urls.empty?

    threads = []
    results_text = []
    valid_urls = []

    urls.each_with_index do |url, index|
      threads << Thread.new do
        begin
          sleep(index * 0.3)
          agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
          response = HTTParty.get(url, headers: { "User-Agent" => agent }, timeout: 8)

          body = response.body.to_s
          is_blocked = [400, 403, 429, 503].include?(response.code)
          is_js_shell = response.code == 200 && (body.length < 1000 || (body.length < 15000 && body.scan(/<script/).length > 10))

          if (is_blocked || is_js_shell) && ZENROWS_API_KEY && !ZENROWS_API_KEY.empty?
            api_url = "https://api.zenrows.com/v1/"
            query_params = { apikey: ZENROWS_API_KEY, url: url, js_render: 'true', antibot: 'true', premium_proxy: 'true', wait: '3000' }
            response = HTTParty.get(api_url, query: query_params, timeout: 25)
          end

          if response && response.code == 200
            doc = Nokogiri::HTML(response.body)
            json_ld = ""
            doc.css('script[type="application/ld+json"]').each { |s| json_ld += s.content.to_s.gsub(/\s+/, " ").strip[0..3000] + " " }
            doc.css('script, style, nav, footer, iframe, header, .cookie').remove
            txt = doc.text.gsub(/\s+/, " ").strip[0..8000]

            if txt.length > 150 || json_ld.length > 100
              Thread.current[:valid] = url
              Thread.current[:text] = "=== SOURCE: #{url} ===\nCONTENT: #{txt}\nJSON-LD: #{json_ld}\n\n"
            end
          end
        rescue => e
          log("Scrape fail url=#{url}: #{e.message}")
        end
      end
    end

    threads.each(&:join)
    threads.each do |t|
      if t[:valid]
        valid_urls << t[:valid]
        results_text << t[:text]
      end
    end

    { text: results_text.join("\n"), valid_urls: valid_urls }
  end

  def fetch_official_ean_data(gtin)
    return nil if EAN_SEARCH_TOKEN.nil? || EAN_SEARCH_TOKEN.empty?
    begin
      url = "https://api.ean-search.org/api?token=#{EAN_SEARCH_TOKEN}&op=barcode-lookup&format=json&ean=#{gtin}"
      resp = HTTParty.get(url, timeout: 4)
      return JSON.parse(resp.body).first if resp.code == 200
    rescue => e
      log("EAN API error: #{e.message}")
    end
    nil
  end

  def analyze_with_gemini(image_data, text_data, official, gtin, market, image_confidence_note = nil)
    target_lang = @country_langs[market] || "English"
    name_info = official ? official['name'] : (official.is_a?(Hash) ? official['name'] : "Unknown")
    
    confidence_note = image_confidence_note ? "\n#{image_confidence_note}\n" : ""

    prompt = <<~TEXT
      You are a Food Data Expert.
      PRODUCT IDENTITY: #{name_info}
      #{confidence_note}
      
      INPUT DATA:
      #{text_data}
      #{image_data && image_data[:base64] ? "IMAGE: Provided" : "IMAGE: Not Available"}

      MARKET REQUIREMENTS:
      - Target Market: #{market}
      - Target Languages: #{target_lang}

      TASK:
      1. Synthesize all data.
      2. **Translation:** Translate Name, Ingredients, and Allergens to **#{target_lang}**.
      3. **BE Specific:** If Market is 'BE', output Ingredients/Allergens in German, French, AND Dutch.
      4. **Nutrition:** Extract ONLY numeric 100g/ml values.
         - Only return actual numbers with units (e.g. "3.2g", "450kJ / 107kcal").
         - Ignore marketing text like "low in fat". Set to null if unavailable.
      5. **Dietary Info:** Select ALL applicable tags (comma-separated):
         Vegetarian, Vegan, Organic, Halal, Kosher, Dairy Free, Nut Free, Low Sugar, High Protein, Gluten Free, Low Fat
         - ONLY apply if explicit text or visible certification exists.
      6. **Format:** Select ONE tag: Multipack, Sharing Size, Single.
      7. **Occasion:** Select ALL applicable tags (comma-separated):
         Breakfast, Lunchbox, BBQ, Party, Christmas, Ramadan, Meal Prep, Quick Dinner, Kids Snack

      OUTPUT JSON (Strict Schema — no extra keys, no markdown):
      {
        "diagnostic_log": "Write a short summary (in English) of exactly what you found in the text and image. If nutritional values are missing, explicitly state WHY (e.g., 'text too short', 'no nutrition table found in the extracted text', 'values were merged and unreadable').",
        "brand": "Brand Name",
        "product_name": "Name (Translated)",
        "net_weight": "Value",
        "ingredients": "List (Translated)",
        "allergens": "List (Translated)",
        "may_contain": "List (Translated)",
        "nutri_scope": "100g",
        "energy": "kJ/kcal",
        "fat": "val",
        "saturates": "val",
        "carbs": "val",
        "sugars": "val",
        "protein": "val",
        "fiber": "val",
        "salt": "val",
        "organic_id": "Code",
        "dietary_info": "Vegetarian, Gluten Free",
        "format": "Single",
        "occasion": "Lunchbox, Kids Snack",
        "sources_summary": "Source description"
      }
    TEXT

    models = ["models/gemini-2.0-flash", "models/gemini-2.0-flash-lite", "models/gemini-1.5-flash"]
    parts = [{ text: prompt }]

    if image_data && image_data[:base64] && image_data[:mime]
      parts << { inline_data: { mime_type: image_data[:mime], data: image_data[:base64] } }
    end

    models.each do |m|
      url = "https://generativelanguage.googleapis.com/v1beta/#{m}:generateContent?key=#{GEMINI_API_KEY}"
      begin
        resp = HTTParty.post(url, body: { contents: [{ parts: parts }] }.to_json, headers: @headers, timeout: 35)
        if resp.code == 200
          raw = resp.dig("candidates", 0, "content", "parts", 0, "text")
          next unless raw
          return JSON.parse(raw.gsub(/```json|```/, "").strip)
        end
      rescue => e
        log("Gemini Model #{m} failed: #{e.message}")
        next
      end
    end
    { "error" => "AI Failed to Analyze" }
  end

  def empty_result(gtin, market, msg, img)
    { found: false, status: msg, gtin: gtin, market: market, image_url: img, defined_sources: [] }
  end
end

# --- ROUTES ---

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  begin
    hunter = MasterDataHunter.new
    result = hunter.process_product(params[:gtin], params[:market])
    result.to_json
  rescue => e
    STDERR.puts("[CRITICAL] Route Error: #{e.class} - #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    { found: false, status: "Server Error", gtin: params[:gtin] }.to_json
  end
end

__END__

@@ index
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>TGTG AI Hunter v5.0 (Diagnostic Ed.)</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f4f6f8; padding: 20px; color: #333; }
    .container { max-width: 98%; margin: 0 auto; background: white; padding: 25px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.08); }
    h1 { color: #00816A; margin-bottom: 20px; }

    .controls { display: flex; gap: 15px; margin-bottom: 20px; background: #eefcf9; padding: 20px; border-radius: 8px; border: 1px solid #ccece6; }
    textarea { width: 100%; height: 100px; padding: 12px; border: 1px solid #ddd; border-radius: 6px; font-family: monospace; font-size: 14px; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: 600; cursor: pointer; transition: background 0.2s; }
    button:hover { background: #006653; }
    button:disabled { background: #ccc; cursor: not-allowed; }

    .table-wrapper { overflow-x: auto; margin-top: 25px; border: 1px solid #e1e4e8; border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 3600px; }
    th { text-align: left; background: #00816A; color: white; padding: 14px 12px; position: sticky; left: 0; z-index: 10; white-space: nowrap; font-weight: 600; letter-spacing: 0.5px; }
    td { padding: 12px; border-bottom: 1px solid #eee; vertical-align: top; max-width: 300px; line-height: 1.4; }
    tr:nth-child(even) { background: #f8f9fa; }
    tr:hover { background: #f1f3f5; }

    .status-badge { padding: 4px 8px; border-radius: 4px; font-weight: 600; font-size: 11px; text-transform: uppercase; }
    .st-found { background: #d4edda; color: #155724; }
    .st-deep  { background: #cce5ff; color: #004085; }
    .st-reg   { background: #fff3cd; color: #856404; }
    .st-miss  { background: #f8d7da; color: #721c24; }
    .img-thumb { width: 50px; height: 50px; object-fit: contain; border: 1px solid #ddd; border-radius: 4px; background: white; padding: 2px; }

    .source-list { display: flex; flex-direction: column; gap: 4px; }
    .src-btn { display: inline-flex; align-items: center; gap: 5px; padding: 4px 8px; border-radius: 4px; font-size: 11px; text-decoration: none; border: 1px solid #ced4da; background: #fff; color: #495057; transition: all 0.2s; width: fit-content; }
    .src-btn:hover { border-color: #00816A; color: #00816A; background: #f0fdf9; }
    .src-registry { border-left: 3px solid #00816A; }
    .src-web      { border-left: 3px solid #007bff; }
    .src-deep     { border-left: 3px solid #fd7e14; }
    .src-img      { border-left: 3px solid #6f42c1; }
    .ai-note { font-size: 10px; color: #888; margin-bottom: 5px; font-style: italic; }

    .tag { display: inline-block; padding: 2px 6px; border-radius: 3px; font-size: 10px; font-weight: 600; margin: 1px; }
    .tag-diet    { background: #d4edda; color: #155724; }
    .tag-format  { background: #cce5ff; color: #004085; }
    .tag-occasion{ background: #fff3cd; color: #856404; }
    
    .btn-log { background: #343a40; color: white; padding: 4px 8px; font-size: 11px; border-radius: 4px; cursor: pointer; border: none; }
    .btn-log:hover { background: #23272b; }
  </style>
</head>
<body>

<div class="container">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <h1>✨ TGTG AI Hunter <span style="font-size:0.5em; color:#666; font-weight:normal;">v5.0 (Diagnostic Ed.)</span></h1>
    <span id="progressIndicator" style="font-weight:bold; color:#00816A;"></span>
  </div>

  <div class="controls">
    <div style="flex:1;">
      <label style="font-weight:bold; display:block; margin-bottom:5px;">Paste EANs (one per line):</label>
      <textarea id="inputList" placeholder="4018077669132..."></textarea>
    </div>
    <div style="width: 200px;">
      <label style="font-weight:bold; display:block; margin-bottom:5px;">Market:</label>
      <select id="marketSelect" style="width:100%; padding:10px; border-radius:6px; border:1px solid #ddd;">
        <option value="BE">Belgium (BE)</option>
        <option value="DK">Denmark (DK)</option>
        <option value="DE">Germany (DE)</option>
        <option value="AT">Austria (AT)</option>
        <option value="NL">Netherlands (NL)</option>
        <option value="FR">France (FR)</option>
        <option value="IT">Italy (IT)</option>
        <option value="ES">Spain (ES)</option>
        <option value="UK">United Kingdom (UK)</option>
        <option value="PL">Poland (PL)</option>
        <option value="SE">Sweden (SE)</option>
        <option value="NO">Norway (NO)</option>
        <option value="FI">Finland (FI)</option>
      </select>
      <button id="startBtn" onclick="startBatch()" style="width:100%; margin-top:10px;">🚀 Analyze</button>
      <button id="downloadBtn" onclick="downloadCSV()" style="width:100%; margin-top:5px; background:#17a2b8; display:none;">⬇️ Download CSV</button>
    </div>
  </div>

  <div class="table-wrapper">
    <table id="resultsTable">
      <thead>
        <tr>
          <th>Status</th>
          <th>🔍 Logs</th>
          <th>Image</th>
          <th>EAN</th>
          <th>Brand</th>
          <th>Product Name</th>
          <th>Origin</th>
          <th>Sources</th>
          <th>Net Weight</th>
          <th>Organic ID</th>
          <th>Ingredients</th>
          <th>Allergens</th>
          <th>May Contain</th>
          <th>Nutri Scope</th>
          <th>Energy</th>
          <th>Fat</th>
          <th>Saturates</th>
          <th>Carbs</th>
          <th>Sugars</th>
          <th>Fiber</th>
          <th>Protein</th>
          <th>Salt</th>
          <th>Dietary Info</th>
          <th>Format</th>
          <th>Occasion</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
  </div>
</div>

<script>
  let resultsData = [];

  async function startBatch() {
    const text = document.getElementById('inputList').value;
    const market = document.getElementById('marketSelect').value;
    const lines = text.split('\n').map(l => l.trim()).filter(l => l.length > 0);
    if (lines.length === 0) { alert("Please paste some EANs first."); return; }

    document.getElementById('startBtn').disabled = true;
    const tbody = document.querySelector('#resultsTable tbody');
    tbody.innerHTML = '';
    resultsData = [];

    const rows = lines.map(gtin => {
      const tr = document.createElement('tr');
      let emptyCells = '';
      for (let i = 0; i < 24; i++) emptyCells += '<td></td>';
      tr.innerHTML = `<td><span class="status-badge" style="background:#eee;color:#666;">...</span></td>` + emptyCells;
      tbody.appendChild(tr);
      resultsData.push(null);
      return tr;
    });

    let processed = 0;
    const updateProgress = () => {
      document.getElementById('progressIndicator').innerText = `Processing: ${processed}/${lines.length}`;
    };
    updateProgress();

    const CONCURRENCY = 3;
    let index = 0;

    async function worker() {
      while (index < lines.length) {
        const i = index++;
        const gtin = lines[i];
        const tr = rows[i];
        try {
          const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
          const data = await response.json();
          resultsData[i] = data;
          renderRow(tr, gtin, data);
        } catch (e) {
          console.error(`Error on EAN ${gtin}:`, e);
          tr.innerHTML = `<td colspan="25" style="color:red;text-align:center;">Error processing ${gtin}</td>`;
        }
        processed++;
        updateProgress();
      }
    }

    await Promise.all(Array.from({ length: CONCURRENCY }, worker));

    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = 'block';
    document.getElementById('progressIndicator').innerText = '✅ Complete';
  }

  function renderTags(val, cssClass) {
    if (!val || val === '-' || val === 'null') return '-';
    return String(val).split(',').map(t => t.trim()).filter(Boolean)
      .map(t => `<span class="tag ${cssClass}">${t}</span>`).join('');
  }

  function showLog(scrapedLength, aiLog) {
    const text = `Scraped Text Length: ${scrapedLength} characters\n\n--- GEMINI THOUGHT PROCESS ---\n${aiLog}`;
    alert(text);
  }

  function renderRow(tr, gtin, data) {
    let sClass = 'st-found';
    if (data.status && data.status.includes('Registry')) sClass = 'st-reg';
    if (data.status && data.status.includes('Deep'))     sClass = 'st-deep';
    if (data.status && (data.status.includes('Error') || data.status.includes('Missing') ||
        data.status.includes('Server') || data.status.includes('Blind'))) sClass = 'st-miss';

    const imgHTML = data.image_url
      ? `<a href="${data.image_url}" target="_blank"><img src="${data.image_url}" class="img-thumb"></a>`
      : '-';

    let sourcesHTML = `<div class="source-list">`;
    if (data.sources_summary) sourcesHTML += `<span class="ai-note">${data.sources_summary}</span>`;
    if (data.defined_sources && data.defined_sources.length > 0) {
      data.defined_sources.forEach(src => {
        let icon = '🔗', cssClass = 'src-web';
        if (src.type === 'registry') { icon = '🏛️'; cssClass = 'src-registry'; }
        if (src.type === 'image')    { icon = '📸'; cssClass = 'src-img'; }
        if (src.type === 'rescue')   { icon = '🔍'; cssClass = 'src-deep'; }
        sourcesHTML += `<a href="${src.url}" target="_blank" class="src-btn ${cssClass}">${icon} ${src.title}</a>`;
      });
    } else {
      sourcesHTML += `<span style="font-size:11px;color:#999;">No links</span>`;
    }
    sourcesHTML += `</div>`;

    const fmt = (val) => {
      if (!val) return '-';
      if (Array.isArray(val)) val = val.join(', ');
      if (typeof val === 'object') val = JSON.stringify(val);
      return String(val).replace(/\n/g, '<br>');
    };
    
    // Safely encode log for HTML attribute
    const safeLog = (data.diagnostic_log || 'No log data').replace(/'/g, "\\'").replace(/"/g, '&quot;');
    const logBtn = `<button class="btn-log" onclick="showLog(${data.text_scraped_length || 0}, '${safeLog}')">🔍 View</button>`;

    tr.innerHTML = `
      <td><span class="status-badge ${sClass}">${data.status || '-'}</span></td>
      <td>${logBtn}</td>
      <td>${imgHTML}</td>
      <td>${gtin}</td>
      <td>${data.brand || '-'}</td>
      <td style="font-weight:bold;">${data.product_name || '-'}</td>
      <td style="text-align:center;">${data.issuing_country || '-'}</td>
      <td>${sourcesHTML}</td>
      <td>${data.net_weight || '-'}</td>
      <td>${data.organic_id || '-'}</td>
      <td style="font-size:11px;">${fmt(data.ingredients)}</td>
      <td style="font-size:11px;">${fmt(data.allergens)}</td>
      <td style="font-size:11px;">${fmt(data.may_contain)}</td>
      <td>${data.nutri_scope || '-'}</td>
      <td>${data.energy || '-'}</td>
      <td>${data.fat || '-'}</td>
      <td>${data.saturates || '-'}</td>
      <td>${data.carbs || '-'}</td>
      <td>${data.sugars || '-'}</td>
      <td>${data.fiber || '-'}</td>
      <td>${data.protein || '-'}</td>
      <td>${data.salt || '-'}</td>
      <td style="font-size:11px;">${renderTags(data.dietary_info, 'tag-diet')}</td>
      <td style="font-size:11px;">${renderTags(data.format, 'tag-format')}</td>
      <td style="font-size:11px;">${renderTags(data.occasion, 'tag-occasion')}</td>`;
  }

  function downloadCSV() {
    let csv = "Status,EAN,Brand,ProductName,Origin,Sources,NetWeight,OrganicID,Ingredients,Allergens,MayContain,NutriScope,Energy,Fat,Saturates,Carbs,Sugars,Fiber,Protein,Salt,DietaryInfo,Format,Occasion\n";
    resultsData.filter(Boolean).forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/\n/g, " | ").trim();
      let srcList = "";
      if (row.defined_sources) {
        srcList = row.defined_sources.map(s => `[${s.type.toUpperCase()}: ${s.url}]`).join(" | ");
      }
      csv += `${row.status},${row.gtin},${clean(row.brand)},${clean(row.product_name)},${clean(row.issuing_country)},` +
             `${srcList},${clean(row.net_weight)},${clean(row.organic_id)},` +
             `${clean(row.ingredients)},${clean(row.allergens)},${clean(row.may_contain)},` +
             `${clean(row.nutri_scope)},${clean(row.energy)},${clean(row.fat)},` +
             `${clean(row.saturates)},${clean(row.carbs)},${clean(row.sugars)},` +
             `${clean(row.fiber)},${clean(row.protein)},${clean(row.salt)},` +
             `${clean(row.dietary_info)},${clean(row.format)},${clean(row.occasion)}\n`;
    });
    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_hunter_results.csv";
    link.click();
  }
</script>

</body>
</html>
