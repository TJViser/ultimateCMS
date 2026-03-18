require 'sinatra/base'
require 'json'
require 'rack/cors'
require 'dotenv/load'
require 'securerandom'

require_relative 'lib/github_client'
require_relative 'lib/edit_agent'
require_relative 'lib/site_store'

module UltimateCMS
  class App < Sinatra::Base
    use Rack::Cors do
      allow do
        origins '*'
        resource '*', headers: :any, methods: [:get, :post, :options]
      end
    end

    set :public_folder, File.join(__dir__, 'public')
    set :site_store, SiteStore.new

    # ============================================
    # PAGES
    # ============================================

    get '/' do
      send_file File.join(settings.public_folder, 'index.html')
    end

    # ============================================
    # SITE REGISTRATION (site owner calls this)
    # ============================================

    # Register a new site — returns a site key
    post '/api/sites' do
      content_type :json
      payload = JSON.parse(request.body.read)

      %w[repo branch github_token].each do |f|
        halt 400, { error: "Missing: #{f}" }.to_json unless payload[f]
      end

      site = settings.site_store.create(
        repo: payload['repo'],
        branch: payload['branch'] || 'main',
        github_token: payload['github_token'],
        allowed_origins: payload['allowed_origins'] || []
      )

      {
        site_key: site[:key],
        embed_script: "<script src=\"#{request.base_url}/ucms.js\" data-site=\"#{site[:key]}\"></script>"
      }.to_json
    end

    # List sites for a GitHub user (authenticated)
    get '/api/sites' do
      content_type :json
      token = extract_token
      halt 401, { error: 'Unauthorized' }.to_json unless token

      sites = settings.site_store.list_for_token(token)
      sites.map { |s| { key: s[:key], repo: s[:repo], branch: s[:branch] } }.to_json
    end

    # ============================================
    # GITHUB OAUTH (for contributors)
    # ============================================

    # Step 1: redirect to GitHub
    get '/auth/github' do
      site_key = params['site']
      client_id = ENV['GITHUB_CLIENT_ID']

      unless client_id
        halt 500, 'GITHUB_CLIENT_ID not configured'
      end

      state = "#{site_key}:#{SecureRandom.hex(8)}"
      redirect_uri = "#{request.base_url}/auth/github/callback"

      redirect "https://github.com/login/oauth/authorize?client_id=#{client_id}&redirect_uri=#{redirect_uri}&state=#{state}&scope=repo"
    end

    # Step 2: GitHub callback
    get '/auth/github/callback' do
      code = params['code']
      state = params['state']

      # Exchange code for access token
      conn = Faraday.new(url: 'https://github.com')
      res = conn.post('/login/oauth/access_token') do |req|
        req.headers['Accept'] = 'application/json'
        req.body = URI.encode_www_form({
          client_id: ENV['GITHUB_CLIENT_ID'],
          client_secret: ENV['GITHUB_CLIENT_SECRET'],
          code: code
        })
      end

      token_data = JSON.parse(res.body)
      access_token = token_data['access_token']

      unless access_token
        halt 401, 'GitHub auth failed'
      end

      # Get user info
      user_conn = Faraday.new(url: 'https://api.github.com')
      user_res = user_conn.get('/user') do |req|
        req.headers['Authorization'] = "Bearer #{access_token}"
        req.headers['Accept'] = 'application/vnd.github.v3+json'
      end
      user = JSON.parse(user_res.body)

      # Create a session token (in production: store in DB / use JWT)
      session_token = SecureRandom.hex(32)
      settings.site_store.save_session(session_token, {
        github_token: access_token,
        username: user['login'],
        avatar: user['avatar_url']
      })

      # Return to the opener window via postMessage
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head><title>Authenticated</title></head>
        <body>
          <script>
            window.opener.postMessage({
              type: 'ucms:auth',
              token: '#{session_token}',
              username: '#{user['login']}',
              avatar: '#{user['avatar_url']}'
            }, '*');
            window.close();
          </script>
        </body>
        </html>
      HTML
    end

    # ============================================
    # EDIT ENDPOINT (called by editor.js)
    # ============================================

    post '/api/edit' do
      content_type :json

      # Authenticate contributor
      session_token = extract_token
      halt 401, { error: 'Not authenticated' }.to_json unless session_token

      contributor = settings.site_store.get_session(session_token)
      halt 401, { error: 'Invalid session' }.to_json unless contributor

      payload = JSON.parse(request.body.read)

      # Look up site config from site key
      site = settings.site_store.get(payload['site_key'])
      halt 404, { error: 'Site not found' }.to_json unless site

      # Verify contributor has access to this repo
      owner, repo = site[:repo].split('/')

      github = GithubClient.new(
        token: contributor[:github_token],  # use contributor's own token for PRs
        owner: owner,
        repo: repo,
        branch: site[:branch]
      )

      agent = EditAgent.new(
        github: github,
        api_key: ENV['ANTHROPIC_API_KEY']
      )

      begin
        result = agent.process(
          page: payload['page'],
          changes: payload['changes']
        )

        { status: 'success', pr_url: result[:pr_url] }.to_json
      rescue => e
        status 500
        { error: e.message }.to_json
      end
    end

    private

    def extract_token
      auth = request.env['HTTP_AUTHORIZATION']
      return nil unless auth
      auth.sub(/^Bearer\s+/i, '')
    end
  end
end
