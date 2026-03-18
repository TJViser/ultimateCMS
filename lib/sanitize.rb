require 'erb'
require 'uri'

module UltimateCMS
  module Sanitize
    # HTML-escape a string to prevent XSS
    def self.escape_html(str)
      return '' unless str
      ERB::Util.html_escape(str.to_s)
    end

    # Escape a string for safe embedding in a JavaScript single-quoted string literal
    def self.escape_js(str)
      return '' unless str
      str.to_s
        .gsub('\\', '\\\\\\\\')
        .gsub("'", "\\\\'")
        .gsub('"', '\\\\"')
        .gsub("\n", '\\n')
        .gsub("\r", '\\r')
        .gsub('/', '\\/')
        .gsub('<', '\\u003c')
        .gsub('>', '\\u003e')
    end

    # Validate and constrain a string field
    def self.valid_string?(str, max_length: 1000, pattern: nil)
      return false unless str.is_a?(String)
      return false if str.length > max_length
      return false if pattern && !str.match?(pattern)
      true
    end

    # Validate a URL (must be http or https)
    def self.valid_url?(url)
      return false unless url.is_a?(String)
      uri = URI.parse(url)
      %w[http https].include?(uri.scheme)
    rescue URI::InvalidURIError
      false
    end

    # Validate a GitHub repo format (owner/repo)
    def self.valid_repo?(repo)
      return false unless repo.is_a?(String)
      repo.match?(/\A[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+\z/)
    end

    # Validate a branch name
    def self.valid_branch?(branch)
      return false unless branch.is_a?(String)
      return false if branch.length > 255
      # No "..", no leading/trailing dots or slashes, no control chars
      return false if branch.include?('..') || branch.include?(' ')
      return false if branch.match?(/[\x00-\x1f\x7f~^:?*\[\\]/)
      true
    end

    # Sanitize text for safe inclusion in a Claude prompt (limit prompt injection surface)
    def self.sanitize_for_prompt(str, max_length: 500)
      return '' unless str.is_a?(String)
      # Truncate, strip control characters (keep newlines/tabs)
      str[0...max_length]
        .gsub(/[^\x09\x0a\x0d\x20-\x7e\u00a0-\uffff]/, '')
    end

    # Sanitize text for inclusion in Markdown (escape markdown special chars)
    def self.escape_markdown(str)
      return '' unless str
      str.to_s.gsub(/([\\`*_\{\}\[\]()#+\-.!|])/, '\\\\\1')
    end
  end
end
