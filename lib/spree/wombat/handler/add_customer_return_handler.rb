module Spree
  module Wombat
    module Handler
      class AddCustomerReturnHandler < Base

        def process
          return response("Please provide a customer_return payload", 400) if customer_return_params.blank?

          customer_return = CustomerReturn.new(stock_location: stock_location, return_items: return_items)

          if customer_return.return_items.length != intended_quantity
            raise "Unable to create the requested amount of return items"
          end

          if customer_return.save
            attempt_to_accept_return_items(customer_return)
            reimburse_customer_return!(customer_return)
            response "Customer return #{customer_return.id} was added", 200
          else
            response "Customer return could not be created, errors: #{customer_return.errors.full_messages}", 400
          end
        rescue => e
          response "Customer return could not be fully processed, errors: #{e}", 500
        end

        private

        def stock_location
          StockLocation.find_by!(name: customer_return_params[:stock_location])
        end

        def return_items
          customer_return_params[:items].flat_map do |item|
            order = Order.includes(inventory_units: [{ return_items: :return_authorization }, :variant]).find_by(number: item[:order_number])
            inventory_units = order.inventory_units.select { |iu| iu.variant.sku == item[:sku] }
            return_items = inventory_units.map(&:current_or_new_return_item)
            return_items = prune_received_return_items(return_items)
            return_items = sort_return_items(return_items)
            return_items.take(item[:quantity].presence || 1)
          end.compact
        end

        def customer_return_params
          @payload[:customer_return]
        end

        def intended_quantity
          customer_return_params[:items].map { |i| i[:quantity] }.sum
        end

        def prune_received_return_items(return_items)
          return_items.select { |ri| !ri.received? }
        end

        def sort_return_items(return_items)
          return_items = return_items.sort { |ri| -(ri.created_at || DateTime.now).to_i }
          return_items = return_items.sort { |ri| ri.return_authorization.try(:number) == customer_return_params[:rma] ? 0 : 1 }
          return_items.sort { |ri| ri.persisted? ? 0 : 1 }
        end

        def attempt_to_accept_return_items(customer_return)
          customer_return.return_items.each(&:attempt_accept)
        end

        def reimburse_customer_return!(customer_return)
          if customer_return.completely_decided? && !customer_return.fully_reimbursed?
            reimbursement = customer_return.reimbursements.create!(
              return_items: customer_return.return_items,
              order: customer_return.order
            )
            reimbursement.perform!
          end
        end
      end
    end
  end
end
