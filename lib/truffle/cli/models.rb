# frozen_string_literal: true

module Truffle
  module CLI
    MODEL_LIST_COLUMNS = [
      [:provider, "provider"],
      [:model, "model"],
      [:context, "context"],
      [:max_out, "max-out"],
      [:thinking, "thinking"],
      [:images, "images"]
    ].freeze

    module_function

    # Table output for `truffle --list-models`. This ports pi's CLI model listing
    # shape: an offline catalog read, optional fuzzy search, provider/model sort,
    # and aligned terminal columns.
    def models_text(models: Truffle.models, search: nil)
      filtered = filter_models(models, search)
      return "No models matching \"#{search}\"\n" if filtered.empty? && present_search?(search)
      return "No models available\n" if filtered.empty?

      rows = filtered.sort_by { |model| [model.provider.to_s, model.id] }
                     .map { |model| model_row(model) }
      widths = model_column_widths(rows)
      lines = [format_model_row(headers: true, widths: widths)]
      lines.concat(rows.map { |row| format_model_row(row: row, widths: widths) })
      "#{lines.join("\n")}\n"
    end

    def filter_models(models, search)
      return models unless present_search?(search)

      pattern = search.to_s.downcase.gsub(/\s+/, "")
      models.select do |model|
        searchable = "#{model.provider} #{model.id} #{model.name}"
        fuzzy_match?(searchable.downcase.gsub(/\s+/, ""), pattern)
      end
    end

    def present_search?(search)
      !search.nil? && search.to_s.strip != ""
    end

    def fuzzy_match?(text, pattern)
      index = 0
      pattern.each_char.all? do |char|
        found = text.index(char, index)
        next false if found.nil?

        index = found + 1
        true
      end
    end

    def model_row(model)
      {
        provider: model.provider.to_s,
        model: model.id,
        context: format_token_count(model.context_window),
        max_out: format_token_count(model.max_output),
        thinking: model.reasoning? ? "yes" : "no",
        images: model.vision? ? "yes" : "no"
      }
    end

    def model_column_widths(rows)
      MODEL_LIST_COLUMNS.to_h do |key, header|
        [key, ([header.length] + rows.map { |row| row.fetch(key).length }).max]
      end
    end

    def format_model_row(widths:, row: nil, headers: false)
      MODEL_LIST_COLUMNS.map do |key, header|
        value = headers ? header : row.fetch(key)
        value.ljust(widths.fetch(key))
      end.join("  ").rstrip
    end

    def format_token_count(count)
      return count.to_s if count < 1_000

      divisor = count >= 1_000_000 ? 1_000_000 : 1_000
      suffix = count >= 1_000_000 ? "M" : "K"
      scaled = count.to_f / divisor
      whole = scaled.to_i
      scaled == whole ? "#{whole}#{suffix}" : "#{format("%.1f", scaled)}#{suffix}"
    end

    private_class_method :filter_models, :present_search?, :fuzzy_match?,
                         :model_row, :model_column_widths, :format_model_row,
                         :format_token_count
  end
end
