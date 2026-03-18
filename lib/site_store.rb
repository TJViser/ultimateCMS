require 'json'
require 'securerandom'

module UltimateCMS
  # Simple file-based store for prototype.
  # In production: replace with PostgreSQL / Redis.
  class SiteStore
    SITES_FILE = File.join(__dir__, '..', 'data', 'sites.json')
    SESSIONS_FILE = File.join(__dir__, '..', 'data', 'sessions.json')
    OAUTH_STATES_FILE = File.join(__dir__, '..', 'data', 'oauth_states.json')

    # Session expiry: 24 hours
    SESSION_TTL = 86_400
    # OAuth state expiry: 10 minutes
    OAUTH_STATE_TTL = 600

    def initialize
      Dir.mkdir(File.dirname(SITES_FILE)) rescue nil
      @sites = load_file(SITES_FILE)
      @sessions = load_file(SESSIONS_FILE)
      @oauth_states = load_file(OAUTH_STATES_FILE)
    end

    # --- Sites ---

    def create(repo:, branch:, github_token:, allowed_origins: [], owner: nil)
      key = "sk_#{SecureRandom.hex(8)}"
      site = {
        key: key,
        repo: repo,
        branch: branch,
        github_token: github_token,
        allowed_origins: allowed_origins,
        owner: owner,
        created_at: Time.now.iso8601
      }
      @sites[key] = site
      save_file(SITES_FILE, @sites)
      site
    end

    def get(key)
      @sites[key]
    end

    def list_for_token(token)
      @sites.values.select { |s| s[:github_token] == token }
    end

    def list_for_owner(username)
      @sites.values.select { |s| s[:owner] == username }
    end

    def update(key, **attrs)
      site = @sites[key]
      return nil unless site

      attrs.each do |k, v|
        site[k] = v unless v.nil?
      end
      site[:updated_at] = Time.now.iso8601
      save_file(SITES_FILE, @sites)
      site
    end

    def delete(key)
      deleted = @sites.delete(key)
      save_file(SITES_FILE, @sites) if deleted
      deleted
    end

    # --- Sessions (with TTL) ---

    def save_session(token, data)
      @sessions[token] = data.merge(created_at: Time.now.iso8601)
      save_file(SESSIONS_FILE, @sessions)
    end

    def get_session(token)
      session = @sessions[token]
      return nil unless session

      # Check expiry
      created = Time.parse(session[:created_at]) rescue nil
      if created && (Time.now - created) > SESSION_TTL
        @sessions.delete(token)
        save_file(SESSIONS_FILE, @sessions)
        return nil
      end

      session
    end

    # --- OAuth States (CSRF protection) ---

    def save_oauth_state(nonce, data)
      cleanup_expired_oauth_states
      @oauth_states[nonce] = data.merge(created_at: Time.now.iso8601)
      save_file(OAUTH_STATES_FILE, @oauth_states)
    end

    def get_oauth_state(nonce)
      state = @oauth_states[nonce]
      return nil unless state

      # Check expiry
      created = Time.parse(state[:created_at]) rescue nil
      return nil if created && (Time.now - created) > OAUTH_STATE_TTL

      state
    end

    def delete_oauth_state(nonce)
      @oauth_states.delete(nonce)
      save_file(OAUTH_STATES_FILE, @oauth_states)
    end

    private

    def cleanup_expired_oauth_states
      @oauth_states.delete_if do |_, state|
        created = Time.parse(state[:created_at]) rescue nil
        created && (Time.now - created) > OAUTH_STATE_TTL
      end
    end

    def load_file(path)
      return {} unless File.exist?(path)
      data = JSON.parse(File.read(path))
      # Symbolize keys for each value
      data.transform_values { |v| v.is_a?(Hash) ? v.transform_keys(&:to_sym) : v }
    rescue
      {}
    end

    def save_file(path, data)
      # Convert symbol keys to strings for JSON
      json_data = data.transform_values { |v| v.is_a?(Hash) ? v.transform_keys(&:to_s) : v }
      File.write(path, JSON.pretty_generate(json_data))
    end
  end
end
