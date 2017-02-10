class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def orders
    order = Order.find_by!(tiramizoo_order_identifier: order_params[:identifier])

    state       = order_params[:state]
    recorded_at = order_params["#{state}_at"]

    ActiveRecord::Base.transaction do
      return true if order.do_nothing?(state)
      LogMissingStateService.new(order, order_params).call
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


class Order < ActiveRecord::Base
  SEQUENCE = { created: 0, dispatched: 1, cancelled: 2, pickup_failed: 3,
    picked_up: 4, delivery_failed: 5, delivered: 6, returned: 7 }

  # Do nothing when current state is farther than new state
  def do_nothing?(new_state)
    SEQUENCE[current_state.to_sym] > SEQUENCE[new_state.to_sym]
  end
end

class LogMissingStateService
  attr_accessor :order, :order_params, :states

  def initialize(order, order_params)
    @order        = order
    @order_params = order_params
    @states       = missing_states
  end

  def call
    return true unless missing_states?
    log_missing_states
  end

  private

  def missing_states?
    states.any?
  end

  def missing_states
    order_params[:history].map do |history|
      history[:type] if order.logs.where(state: history[:type]).blank?
    end.compact
  end

  def log_missing_states
    states.each do |state|
      # Log missing states. Need to add proper logic. Methods naming: add_missing_STATE
      # order.logs.create!(state: state ...)
      public_send("add_missing_#{state}")
    end
  end

  def add_missing_pick_up
    pick_up_event        = order_params[:history].detect{|history| history[:type] == "pick_up"}
    order.signature_name = pick_up_event[:signature].try(:[], :name)
    order.signature_url  = pick_up_event[:signature].try(:[], :url)
    order.logs.create!(state: "picked_up", recorded_at: pick_up_event[:recorded_at])
  end

end
