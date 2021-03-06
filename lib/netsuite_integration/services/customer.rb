module NetsuiteIntegration
  module Services
    class Customer < Base

      def find_by_external_id(email)
        NetSuite::Records::Customer.get({:external_id => email})
      # Silence the error
      # We don't care that the record was not found
      rescue NetSuite::RecordNotFound
      end

      # entity_id -> Customer name
      def create(payload)
        customer             = NetSuite::Records::Customer.new
        customer.email       = payload[:email]
        customer.external_id = payload[:email]

        if payload[:shipping_address]
          customer.first_name  = payload[:shipping_address][:firstname] || 'N/A'
          customer.last_name   = payload[:shipping_address][:lastname] || 'N/A'
          fill_address(customer, payload[:shipping_address])
        else
          customer.first_name  = 'N/A'
          customer.last_name   = 'N/A'
        end

        # Defaults
        customer.is_person   = true
        # I don't think we need to make the customer inactive
        # customer.is_inactive = true

        if customer.add
          customer
        else
          false
        end
      end

      def update_attributes(customer, attrs)
        attrs.delete :id
        attrs.delete :created_at
        attrs.delete :updated_at

        # Converting string keys to symbol keys
        # Netsuite gem does not like string keys
        attrs = Hash[attrs.map{|(k,v)| [k.to_sym,v]}]

        if customer.update attrs
          customer
        else
          false
        end
      end

      def has_changed_address?(customer, payload)
        current = {
          addr1: payload[:address1],
          addr2: payload[:address2],
          zip: payload[:zipcode],
          city: payload[:city],
          state: StateService.by_state_name(payload[:state]),
          country: CountryService.by_iso_country(payload[:country]),
          phone: payload[:phone].gsub(/([^0-9]*)/, "")
        }

        existing_addresses(customer).none? do |address|
          address.delete :default_shipping
          address == current
        end
      end

      def set_or_create_default_address(customer, payload)
        attrs = [{
          default_shipping: true,
          addr1: payload[:address1],
          addr2: payload[:address2],
          zip: payload[:zipcode],
          city: payload[:city],
          state: StateService.by_state_name(payload[:state]),
          country: CountryService.by_iso_country(payload[:country]),
          phone: payload[:phone].gsub(/([^0-9]*)/, "")
        }]

        existing = existing_addresses(customer).map do |a|
          a[:default_shipping] = false
          a
        end

        customer.update addressbook_list: { addressbook: attrs.push(existing).flatten }
      end

      private
        def existing_addresses(customer)
          customer.addressbook_list.addressbooks.map do |addr|
            {
              default_shipping: addr.default_shipping,
              addr1: addr.addr1.to_s,
              addr2: addr.addr2.to_s,
              zip: addr.zip.to_s,
              city: addr.city.to_s,
              state: addr.state.to_s,
              country: addr.country.to_s,
              phone: addr.phone.gsub(/([^0-9]*)/, "")
            }
          end
        end

        def fill_address(customer, payload)
          if payload[:address1].present?
            customer.addressbook_list = {
              addressbook: {
                default_shipping: true,
                addr1: payload[:address1],
                addr2: payload[:address2],
                zip: payload[:zipcode],
                city: payload[:city],
                state: StateService.by_state_name(payload[:state]),
                country: CountryService.by_iso_country(payload[:country]),
                phone: payload[:phone].gsub(/([^0-9]*)/, "")
              }
            }
          end
        end
    end
  end
end
