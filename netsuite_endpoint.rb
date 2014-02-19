require "sinatra"
require "endpoint_base"

require File.expand_path(File.dirname(__FILE__) + '/lib/netsuite_integration')

class NetsuiteEndpoint < EndpointBase::Sinatra::Base
  before do
    print "  Start NetSuite API Request at #{Time.now} for #{request.path}"

    if config = @config
      @netsuite_client ||= NetSuite.configure do
        reset!
        api_version  '2013_2'
        wsdl         'https://webservices.na1.netsuite.com/wsdl/v2013_2_0/netsuite.wsdl'
        sandbox      false
        email        config.fetch('netsuite.email')
        password     config.fetch('netsuite.password')
        account      config.fetch('netsuite.account')
        read_timeout 175
        log_level    :info
      end
    end
  end

  after do
    print "  End NetSuite API Request at #{Time.now} for #{request.path}"
  end

  post '/products' do
    begin
      products = NetsuiteIntegration::Product.new(@config)

      if products.collection.any?
        add_messages "product:import", products.messages
        add_parameter 'netsuite.last_updated_after', products.last_modified_date
        add_notification "info", "#{products.messages.count} items found in NetSuite"
      end

      process_result 200
    rescue StandardError => e
      add_notification "error", e.message, nil, { backtrace: e.backtrace.to_a.join("\n\t") }
      process_result 500
    end
  end

  post '/add_order' do
    begin
      create_or_update_order
    rescue StandardError => e
      set_summary "#{e.message}: #{e.backtrace.to_a.join('\n\t')}"
      process_result 500
    end
  end

  post '/update_order' do
    begin
      if ['canceled', 'cancelled'].include? @payload['order']
        cancel_order
      else
        create_or_update_order
      end
    rescue StandardError => e
      set_summary "#{e.message}: #{e.backtrace.to_a.join('\n\t')}"
      process_result 500
    end
  end

  post '/inventory_stock' do
    begin
      stock = NetsuiteIntegration::InventoryStock.new(@config, @message)
      add_message 'stock:actual', { sku: stock.sku, quantity: stock.quantity_available }
      add_notification "info", "#{stock.quantity_available} units available of #{stock.sku} according to NetSuite"
      process_result 200
    rescue NetSuite::RecordNotFound
      process_result 200
    rescue => e
      add_notification "error", e.message, e.backtrace.to_a.join("\n")
      process_result 500
    end
  end

  post '/shipments' do
    begin
      order = NetsuiteIntegration::Shipment.new(@message, @config).import
      add_notification "info", "Order #{order.external_id} fulfilled in NetSuite # #{order.tran_id}"
      process_result 200
    rescue StandardError => e
      add_notification "error", e.message, e.backtrace.to_a.join("\n")
      process_result 500
    end
  end

  private
  def create_or_update_order
    order = NetsuiteIntegration::Order.new(@config, @payload[:order])

    unless order.imported?
      if order.import
        set_summary "Order #{order.sales_order.external_id} sent to NetSuite # #{order.sales_order.tran_id}"
        process_result 200
      else
        set_summary "Failed to import order #{order.sales_order.external_id} into Netsuite" # Where to add order.errors?
        process_result 500
      end
    else
      if order.got_paid?
        if order.create_customer_deposit
          set_summary "Customer Deposit created for NetSuite Sales Order #{order.sales_order.external_id}"
          process_result 200
        else
          set_summary "Failed to create a Customer Deposit for NetSuite Sales Order #{order.sales_order.external_id}"
          process_result 500
        end
      else
        process_result 200
      end
    end
  end

  def cancel_order
    order = sales_order_service.find_by_external_id(@payload[:order][:number]) or 
      raise RecordNotFoundSalesOrder, "NetSuite Sales Order not found for order #{order_payload[:number]}"

    if customer_record_exists?
      sales_order_service.close!(order)
      set_summary "NetSuite Sales Order #{@payload[:order][:number]} was closed"
      process_result 200
    else
      refund = NetsuiteIntegration::Refund.new(@config, @payload[:order], order)
      if refund.process!
        set_summary "Customer Refund created and NetSuite Sales Order #{@payload[:order][:number]} was closed"
        process_result 200
      else
        set_summary "Failed to create a Customer Refund and close the NetSuite Sales Order #{@payload[:order][:number]}"
        process_result 500
      end      
    end
  end

  def customer_record_exists?
    @message[:payload][:original][:payment_state] == 'balance_due'
  end

  def sales_order_service
    @sales_order_service ||= NetsuiteIntegration::Services::SalesOrder.new(@config)
  end
end
