require 'jwt'
require 'openssl'
require 'base64'
require 'json'

module UltimateCMS
  module JwtSession
    ALGORITHM = 'HS256'
    TTL = 86_400 # 24 hours
    LEEWAY = 30  # 30 seconds clock skew tolerance

    # Encode a session into a signed JWT
    # payload_hash: { username:, avatar:, github_token:, flow:, site_key: (optional) }
    def self.encode(payload_hash)
      secret = jwt_secret

      payload = {
        username: payload_hash[:username],
        avatar: payload_hash[:avatar],
        ght: encrypt_token(payload_hash[:github_token]), # encrypted github token
        flow: payload_hash[:flow],
        exp: Time.now.to_i + TTL,
        iat: Time.now.to_i
      }
      payload[:site_key] = payload_hash[:site_key] if payload_hash[:site_key]

      JWT.encode(payload, secret, ALGORITHM)
    end

    # Decode and verify a JWT, returns a symbolized hash matching the old session format
    # Returns nil on any error
    def self.decode(token)
      secret = jwt_secret

      decoded = JWT.decode(token, secret, true, {
        algorithm: ALGORITHM,
        exp_leeway: LEEWAY
      })

      payload = decoded[0] # first element is the payload, second is the header

      {
        username: payload['username'],
        avatar: payload['avatar'],
        github_token: decrypt_token(payload['ght']),
        flow: payload['flow'],
        site_key: payload['site_key']
      }
    rescue JWT::ExpiredSignature
      nil
    rescue JWT::DecodeError
      nil
    rescue OpenSSL::Cipher::CipherError
      nil
    end

    # Encrypt a plaintext string with AES-256-GCM
    # Returns: base64(iv):base64(ciphertext):base64(auth_tag)
    def self.encrypt_token(plaintext)
      return nil unless plaintext

      key = encryption_key
      cipher = OpenSSL::Cipher::AES.new(256, :GCM).encrypt
      cipher.key = key
      iv = cipher.random_iv
      cipher.iv = iv

      ciphertext = cipher.update(plaintext) + cipher.final
      auth_tag = cipher.auth_tag

      [
        Base64.urlsafe_encode64(iv, padding: false),
        Base64.urlsafe_encode64(ciphertext, padding: false),
        Base64.urlsafe_encode64(auth_tag, padding: false)
      ].join(':')
    end

    # Decrypt a string encrypted by encrypt_token
    def self.decrypt_token(encrypted)
      return nil unless encrypted

      parts = encrypted.split(':')
      return nil unless parts.length == 3

      iv = Base64.urlsafe_decode64(parts[0])
      ciphertext = Base64.urlsafe_decode64(parts[1])
      auth_tag = Base64.urlsafe_decode64(parts[2])

      key = encryption_key
      cipher = OpenSSL::Cipher::AES.new(256, :GCM).decrypt
      cipher.key = key
      cipher.iv = iv
      cipher.auth_tag = auth_tag

      cipher.update(ciphertext) + cipher.final
    end

    def self.jwt_secret
      secret = ENV['JWT_SECRET']
      raise 'JWT_SECRET not configured' unless secret && !secret.empty?
      secret
    end
    private_class_method :jwt_secret

    def self.encryption_key
      hex_key = ENV['TOKEN_ENCRYPTION_KEY']
      raise 'TOKEN_ENCRYPTION_KEY not configured' unless hex_key && hex_key.length == 64
      [hex_key].pack('H*') # 64 hex chars → 32 bytes
    end
    private_class_method :encryption_key
  end
end
