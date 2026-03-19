require 'faraday'
require 'json'
require 'base64'

module UltimateCMS
  class GithubClient
    API_BASE = 'https://api.github.com'

    attr_reader :owner, :repo, :branch

    def initialize(token:, owner:, repo:, branch: 'main')
      @owner = owner
      @repo = repo
      @branch = branch
      @conn = Faraday.new(url: API_BASE) do |f|
        f.request :json
        f.response :json
        f.headers['Authorization'] = "Bearer #{token}"
        f.headers['Accept'] = 'application/vnd.github.v3+json'
        f.headers['User-Agent'] = 'UltimateCMS'
      end
    end

    # Search for text across the repo
    def search_code(query)
      res = @conn.get('/search/code', {
        q: "#{query} repo:#{@owner}/#{@repo}"
      })
      raise "GitHub search failed (#{res.status})" unless res.success?
      res.body['items'] || []
    end

    # Get file content
    def get_file(path, ref: nil)
      ref ||= @branch
      res = @conn.get("/repos/#{@owner}/#{@repo}/contents/#{path}", { ref: ref })
      raise "File not found: #{path}" unless res.success?

      content = Base64.decode64(res.body['content'])
      content.force_encoding('UTF-8')

      {
        content: content,
        sha: res.body['sha'],
        path: res.body['path']
      }
    end

    # Get the repo tree (list all files)
    def get_tree
      res = @conn.get("/repos/#{@owner}/#{@repo}/git/trees/#{@branch}", { recursive: 1 })
      raise "Cannot read repo tree (#{res.status})" unless res.success?

      res.body['tree']
        .select { |f| f['type'] == 'blob' }
        .map { |f| f['path'] }
    end

    # Get the latest commit SHA for the branch
    def get_branch_sha
      res = @conn.get("/repos/#{@owner}/#{@repo}/git/ref/heads/#{@branch}")
      raise "Cannot read branch (#{res.status})" unless res.success?
      res.body['object']['sha']
    end

    # Create a new branch from the current branch
    def create_branch(name)
      sha = get_branch_sha
      res = @conn.post("/repos/#{@owner}/#{@repo}/git/refs") do |req|
        req.body = { ref: "refs/heads/#{name}", sha: sha }
      end
      raise "Cannot create branch (#{res.status})" unless res.success?
      name
    end

    # Update a file on a branch
    def update_file(path:, content:, sha:, branch:, message:)
      encoded = Base64.strict_encode64(content)
      res = @conn.put("/repos/#{@owner}/#{@repo}/contents/#{path}") do |req|
        req.body = {
          message: message,
          content: encoded,
          sha: sha,
          branch: branch
        }
      end
      raise "Cannot update file (#{res.status})" unless res.success?
      res.body
    end

    # Create a pull request
    def create_pull_request(title:, body:, head:, base: nil)
      base ||= @branch
      res = @conn.post("/repos/#{@owner}/#{@repo}/pulls") do |req|
        req.body = {
          title: title,
          body: body,
          head: head,
          base: base
        }
      end
      raise "Cannot create PR (#{res.status})" unless res.success?
      res.body['html_url']
    end
  end
end
