require 'lita'
require 'securerandom'
require 'json'
module Lita
  module Handlers
    class Nagios < Handler

      def self.default_config(config)
        config.room = nil
        config.nagios_url = nil
        config.user = nil
        config.password = nil
        config.redis_namespace = nil
      end

      @@silent = false
      http.post "nagios", :nagios
      route /nagios silent/, :nagios_silent
      route /nagios verbose/, :nagios_verbose
      route /nagios ack (\w+) (.*)/, :nagios_ack

      def genuid
        Digest::SHA1.hexdigest(SecureRandom.uuid.gsub('-','').upcase)[0..8]
      end

      def nagios_silent(response)
        @@silent = true
      end

      def nagios_verbose(response)
        @@silent = false
      end

      def nagios_ack(response)
        dest = Source.new(room: Lita.config.handlers.nagios.room)
        key = "#{Lita.config.handlers.nagios.redis_namespace}-#{response.matches[0][0]}"
        value = redis.get key
        if value.empty?
          response.reply("ID not found")
        else
          value = JSON.load(value)
          case value['type']
            when 'host'
                res = nagios_cmd(33, host: value['host'],
                               com_author: 'arnaud',
                               com_data: response.matches[0][1],
                               send_notification: 'on',
                               sticky_ack: 'on'
                               ) 
            when 'service'
                res = nagios_cmd(34, host: value['host'],
                               service: value['service'],
                               com_author: 'arnaud',
                               com_data: response.matches[0][1],
                               send_notification: 'on',
                               sticky_ack: 'on'
                               ) 
          end
          if res
            response.reply("OK command accepted")
          else
            response.reply("Can't send command")
          end
        end
      end

      def nagios_cmd(type, params)
        request = URI.parse(Lita.config.handlers.nagios.nagios_url)
        http_req = http
        http_req.basic_auth Lita.config.handlers.nagios.user,
                            Lita.config.handlers.nagios.password
        http_req.request :url_encoded
        args = { cmd_mod: 2, cmd_typ: type }.merge(params)
        http_res = http_req.post(Lita.config.handlers.nagios.nagios_url,
                         args)
        !!http_res.body.match(/Your command request was successfully submitted to the Backend for processing/)
      end

      def nagios(request, response)
        return if @@silent == true
        params = request.env['rack.input'].read
        data = Rack::Utils.parse_query(params)
        dest = Source.new(room: Lita.config.handlers.nagios.room)
        uid = genuid
        return if data['state'] == 'WARNING'
        if data.has_key?('type')
          case data['type']
          when 'host'
            host = data['host']
            notificationtype = data['notificationtype']
            state = data['state']
            output = data['output']
            cache_alert uid, { type: 'host', host: host }.to_json
            robot.send_message(dest, "#{state} #{notificationtype}: #{host} result: #{output} -- #{uid}")
          when 'service'
            host = data['host']
            notificationtype = data['notificationtype']
            service = data['description']
            state = data['state']
            output = data['output']
            cache_alert uid, { type: 'service', host: host, service: service }.to_json
            robot.send_message(dest, "#{state} #{notificationtype}: #{host} - #{service}, result: #{output} -- #{uid}")
          end
        else
          response.status = 400
          response.write('Type missing')
        end
      end

      def cache_alert(uid, value)
        key = "#{Lita.config.handlers.nagios.redis_namespace}-#{uid}"
        redis.set key, value
        redis.expire key, 3600
      end

    end
    Lita.register_handler(Nagios)
  end
end
 
