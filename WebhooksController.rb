class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def orders
    order = Order.find_by!(tiramizoo_order_identifier: order_params[:identifier])

    state       = order_params[:state]
    recorded_at = order_params["#{state}_at"]

    ActiveRecord::Base.transaction do
      order.current_state = state

      case order.current_state
      when "cancelled"
        order.logs.create!(state: state, recorded_at: recorded_at)
        Mailer.delay.cancellation_confirmation(order.id) if order.current_state_changed?

      when "pickup_failed"
        event = order_params[:events].detect {|e| e["current_state"] == "pickup_failed"}
        order.logs.create!({
          state:          state,
          recorded_at:    recorded_at,
          signature_name: event[:signature].try(:[], :name),
          signature_url:  event[:signature].try(:[], :url)
        })

        event["type"] == "sender_was_not_at_home" ?
          Mailer.delay.courier_failed_to_locate_address(order.id) :
          Mailer.delay.packages_not_ready(order.id)

      when "picked_up"
        order.signature_name = order_params[:pickup_signature].try(:[], :name)
        order.signature_url  = order_params[:pickup_signature].try(:[], :url)
        order.logs.create!(state: state, recorded_at: recorded_at)
        Mailer.delay.pickup_confirmation(order.id)
        if order_params[:real_time_tracking_available]
          Delayed::Job.enqueue SmsNotificationJob.new(order.id)
        end
      when "delivered"
        unless order.logs.where(state: "picked_up").exists?
          pick_up_event        = order_params[:history].detect{|history| history[:type] == "pick_up"}
          order.signature_name = pick_up_event[:signature].try(:[], :name)
          order.signature_url  = pick_up_event[:signature].try(:[], :url)
          order.logs.create!(state: "picked_up", recorded_at: pick_up_event[:recorded_at])
        end
        order.logs.create!(state: state, recorded_at: recorded_at)
      else # returned / delivery_failed
        order.logs.create!(state: state, recorded_at: recorded_at)
      end

      order.save!
    end

    head :ok
  end

  private

  def order_params
    params.require(:state)
    params.require(:identifier)
    params.permit(:state, :identifier, :real_time_tracking_available, :picked_up_at, :pickup_failed_at, :delivered_at, :delivery_failed_at, :returned_at, :cancelled_at, pickup_signature: [:name, :url], events: [:type, :current_state, signature: [:name, :url]], history: [:type, :recorded_at, signature: [:url, :name]])
  end
end