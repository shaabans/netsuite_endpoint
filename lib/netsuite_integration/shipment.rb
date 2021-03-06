module NetsuiteIntegration
  class Shipment < Base
    attr_reader :config

    def import
      create_item_fulfillment
      create_invoice

      order
    end

    def create_invoice
      return unless order_pending_billing?

      invoice = NetSuite::Records::Invoice.new({
        tax_rate: 0,
        is_taxable: false,
        created_from: {
          internal_id: order_id
        }
      })

      invoice.add
      verify_errors(invoice)
    end

    def create_item_fulfillment
      return unless order_pending_fulfillment?

      fulfillment = NetSuite::Records::ItemFulfillment.new({
        created_from: {
          internal_id: order_id
        },
        transaction_ship_address: {
          ship_addressee: "#{address[:firstname]} #{address[:lastname]}",
          ship_addr1:     address[:address1],
          ship_addr2:     address[:address2],
          ship_zip:       address[:zipcode],
          ship_city:      address[:city],
          ship_state:     Services::StateService.by_state_name(address[:state]),
          ship_country:   Services::CountryService.by_iso_country(address[:country]),
          ship_phone:     address[:phone].gsub(/([^0-9]*)/, "")
        }
      })

      @fulfilled = fulfillment.add
      verify_errors(fulfillment)
    end

    def messages
      latest_fulfillments.map do |shipment|
        {
          id: shipment.internal_id,
          order_id: sales_orders_for_shipment(shipment.created_from.internal_id).external_id,
          cost: shipment.shipping_cost,
          status: shipment.ship_status[1..-1],
          shipping_method: try_shipping_method(shipment),
          tracking: shipment.package_list.packages.map(&:package_tracking_number).join(", "),
          shipped_at: shipment.tran_date,
          shipping_address: build_shipping_address(shipment.transaction_ship_address),
          items: build_item_list(shipment.item_list.items)
        }
      end
    end

    def last_modified_date
      latest_fulfillments.last.last_modified_date.utc + 1.second
    end

    def latest_fulfillments
      @latest_fulfillments ||= Services::ItemFulfillment.new(config).latest
    end

    private
      def sales_orders_for_shipment(internal_id)
        sales_order_list[internal_id] ||= NetSuite::Records::SalesOrder.get(internal_id)
      end

      def sales_order_list
        @sales_order_list ||= {}
      end

      def order_pending_fulfillment?
        order.status == 'Pending Fulfillment'
      end

      def order_pending_billing?
        @fulfilled || order.status == 'Pending Billing'
      end

      def order_id
        order.internal_id
      end

      def order
        @order ||= sales_order_service.find_by_external_id(payload[:shipment][:order_number] || payload[:shipment][:order_id])
      end

      def address
        payload[:shipment][:shipping_address]
      end

      def verify_errors(object)
        unless (errors = (object.errors || []).select {|e| e.type == "ERROR"}).blank?
          text = errors.inject("") {|buf, cur| buf += cur.message}

          raise StandardError.new(text) if text.length > 0
        else
          object
        end
      end

      def build_item_list(items)
        items.map do |item|
          {
            name: item.item.name,
            product_id: item.item.name,
            quantity: item.quantity.to_i,
          }
        end
      end

      def build_shipping_address(address)
        if address && address.ship_addressee
          firstname, lastname = address.ship_addressee.split(" ")

          {
            firstname: firstname,
            lastname: lastname,
            address1: address.ship_addr1,
            address2: address.ship_addressee,
            zipcode: address.ship_zip,
            city: address.ship_city,
            state: Services::StateService.by_state_name(address.ship_state),
            country: normalize_country_name(address.ship_country),
            phone: address.ship_phone
          }
        end
      end

      def try_shipping_method(shipment)
        if shipment.ship_method
          shipment.ship_method.name
        end
      rescue NoMethodError => e
        nil
      end

      # See https://system.netsuite.com/help/helpcenter/en_US/SchemaBrowser/platform/v2013_2_0/commonTypes.html#platformCommonTyp:Country
      #
      #   _unitedStates => UnitedStates
      #
      def normalize_country_name(name)
        if name.is_a? String
          name = name[1..-1]
          "#{name[0].upcase}#{name[1..-1]}"
        end
      end
  end
end
